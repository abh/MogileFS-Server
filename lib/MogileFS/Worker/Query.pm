package MogileFS::Worker::Query;
# responds to queries from Mogile clients

use strict;
use warnings;

use base 'MogileFS::Worker';
use fields qw(querystarttime reqid);

sub new {
    my ($class, $psock) = @_;
    my $self = fields::new($class);
    $self->SUPER::new($psock);

    $self->{querystarttime} = undef;
    $self->{reqid}          = undef;
    return $self;
}

# no query should take 10 seconds, and we check in every 5 seconds.
sub watchdog_timeout { 10 }

sub work {
    my $self = shift;
    my $psock = $self->{psock};
    my $rin = '';
    vec($rin, fileno($psock), 1) = 1;
    my $buf;

    while (1) {
        my $rout;
        unless (select($rout=$rin, undef, undef, 5.0)) {
            $self->still_alive;
            next;
        }
            
        my $newread;
        my $rv = sysread($psock, $newread, 1024);
        $buf .= $newread;

        while ($buf =~ s/^(.+?)\r?\n//) {
            my $line = $1;
            $self->validate_dbh;
            if ($self->process_generic_command(\$line)) {
                $self->still_alive;  # no-op for watchdog
            } else {
                $self->process_line(\$line);
            }
        }
    }
}

sub process_line {
    my MogileFS::Worker::Query $self = shift;
    my $lineref = shift;

    # see what kind of command this is
    return $self->err_line('unknown_command')
        unless $$lineref =~ /^(\d+-\d+)?\s*(\S+)\s*(.*)/;

    $self->{reqid} = $1 || undef;
    my ($client_ip, $line) = ($2, $3);

    # set global variables for zone determination
    Mgd::set_client_ip($client_ip);
    Mgd::set_force_altzone(0);

    # fallback to normal command handling
    if ($line =~ /^(\w+)\s*(.*)/) {
        my ($cmd, $args) = ($1, $2);
        $cmd = lc($cmd);

        no strict 'refs';
        $self->{querystarttime} = Time::HiRes::gettimeofday();
        my $cmd_handler = *{"cmd_$cmd"}{CODE};
        if ($cmd_handler) {
            my $args = decode_url_args(\$args);
            Mgd::set_force_altzone(1) if $args->{zone} && $args->{zone} eq 'alt';
            $cmd_handler->($self, $args);
            return;
        }
    }

    return $self->err_line('unknown_command');
}

# returns 0 on error, or dmid of domain
sub check_domain {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    return $self->err_line("no_domain") unless length($args->{domain});

    # validate domain
    my $dmid = Mgd::domain_id($args->{domain}) or
        return $self->err_line("unreg_domain");

    return $dmid;
}

sub cmd_sleep {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;
    sleep($args->{duration} || 10);
    return $self->ok_line;
}

sub cmd_clear_cache {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    if ($args->{devices} || $args->{all}) {
        Mgd::invalidate_device_cache();
    }
    if ($args->{hosts} || $args->{all}) {
        Mgd::invalidate_host_cache();
    }

    return $self->ok_line;
}

sub cmd_create_open {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # validate parameters
    my $dmid = $self->check_domain($args) or return 0;
    my $key = $args->{key} || "";
    my $multi = $args->{multi_dest} ? 1 : 0;
    my $fid = ($args->{fid} + 0) || undef; # we want it to be undef if they didn't give one
                                           # and we want to force it numeric...

    # get DB handle
    my $dbh = Mgd::get_dbh() or
        return $self->err_line("nodb");

    # figure out what classid this file is for
    my $class = $args->{class};
    my $classid = 0;
    if (length($class)) {
        # TODO: cache this
        $classid = $dbh->selectrow_array("SELECT classid FROM class ".
                                         "WHERE dmid=? AND classname=?",
                                         undef, $dmid, $class)
            or return $self->err_line("unreg_class");
    }

    # find a device to put this file on that has 100Mb free.
    my (@dests, @hosts);
    my $devs = Mgd::get_device_summary();
    while (scalar(@dests) < ($multi ? 3 : 1)) {
        my $devid = Mgd::find_deviceid(
            random => 1,
            weight_by_free => 1,
            not_on_hosts => \@hosts,
        );

        last unless defined $devid;

        push @dests, $devid;
        push @hosts, $devs->{$devid}->{hostid};
    }
    return $self->err_line("no_devices") unless @dests;

    my $explicit_fid_used = $fid ? 1 : 0;
    # setup the new mapping.  we store the devices that we picked for
    # this file in here, knowing that they might not be used.  create_close
    # is responsible for actually mapping in file_on.  NOTE: fid is being
    # passed in, it's either some number they gave us, or it's going to be
    # undef which translates into NULL which means to automatically create
    # one.  that should be fine.
    my $ins_tempfile = sub {
        $dbh->do("INSERT INTO tempfile SET ".
                 " fid=?, dmid=?, dkey=?, classid=?, createtime=UNIX_TIMESTAMP(), devids=?",
                 undef, $fid, $dmid, $key, $classid, join(',', @dests));
        return undef if $dbh->err;
        unless (defined $fid) {
            # if they did not give us a fid, then we want to grab the one that was
            # theoretically automatically generated
            $fid = $dbh->{mysql_insertid};  # FIXME: mysql-ism
        }
        return undef unless defined $fid && $fid > 0;
        return 1;
    };

    return undef unless $ins_tempfile->();

    my $fid_in_use = sub {
        my $exists = $dbh->selectrow_array("SELECT COUNT(*) FROM file WHERE fid=?", undef, $fid);
        die if $dbh->err;
        return $exists ? 1 : 0;
    };

    # if the fid is in use, do something
    while ($fid_in_use->($fid)) {
        return $self->err_line("fid_in_use") if $explicit_fid_used;

        # mysql could have been restarted with an empty tempfile table, causing
        # innodb to reuse a fid number.  so we need to seed the tempfile table...

        # get the highest fid from the filetable and insert a dummy row
        $fid = $dbh->selectrow_array("SELECT MAX(fid) FROM file");
        $ins_tempfile->();

        # then do a normal auto-increment
        $fid = undef;
        return undef unless $ins_tempfile->();
    }

    # make sure directories exist for client to be able to PUT into
    foreach my $devid (@dests) {
        my $path = Mgd::make_path($devid, $fid);
        Mgd::vivify_directories($path);
    }

    # original single path support
    return $self->ok_line({
        fid => $fid,
        devid => $dests[0],
        path => Mgd::make_path($dests[0], $fid),
    }) unless $multi;

    # multiple path support
    my $ct = 0;
    my $res = {};
    foreach my $devid (@dests) {
        $ct++;
        $res->{"devid_$ct"} = $devid;
        $res->{"path_$ct"} = Mgd::make_path($devid, $fid);
    }
    $res->{fid} = $fid;
    $res->{dev_count} = $ct;
    return $self->ok_line($res);
}

sub cmd_create_close {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # validate parameters
    my $dmid = $self->check_domain($args) or return 0;
    my $key = $args->{key};

    my $fid = $args->{fid} or return $self->err_line("no_fid");
    my $devid = $args->{devid} or return $self->err_line("no_devid");
    my $path = $args->{path} or return $self->err_line("no_path");

    # is the provided path what we'd expect for this fid/devid?
    return $self->err_line("bogus_args")
        unless $path eq Mgd::make_path($devid, $fid);

    # get DB handle
    my $dbh = Mgd::get_dbh() or
        return $self->err_line("nodb");

    # find the temp file we're closing and making real
    my $trow = $dbh->selectrow_hashref("SELECT classid, dmid, dkey ".
                                       "FROM tempfile WHERE fid=?",
                                       undef, $fid);
    return $self->err_line("no_temp_file") unless $trow;

    # if a temp file is closed without a provided-key, that means to
    # delete it.
    unless (length($key)) {
        # add to to-delete list
        $dbh->do("REPLACE INTO file_to_delete SET fid=?", undef, $fid);
        $dbh->do("DELETE FROM tempfile WHERE fid=?", undef, $fid);
        return $self->ok_line;
    }

    # see if we have a fid for this key already
    my $old_file = Mgd::key_filerow($dbh, $dmid, $key);
    if ($old_file) {
        # add to to-delete list
        $dbh->do("REPLACE INTO file_to_delete SET fid=?", undef, $old_file->{fid});
        $dbh->do("DELETE FROM file WHERE fid=?", undef, $old_file->{fid});
    }

    # get size of file and verify that it matches what we were given, if anything
    my $size = Mgd::get_file_size($path);

    return $self->err_line("size_mismatch", "Expected: $args->{size}; actual: $size; path: $path")
        if $args->{size} && ($args->{size} != $size);

    # TODO: check for EIO?
    return $self->err_line("empty_file") unless $size;

    # insert file_on row
    $dbh->do("INSERT IGNORE INTO file_on SET fid = ?, devid = ?", undef, $fid, $devid);
    return $self->err_line("db_error") if $dbh->err;

    my $rv = $dbh->do("REPLACE INTO file ".
                      "SET ".
                      "  fid=?, dmid=?, dkey=?, length=?, ".
                      "  classid=?, devcount=0", undef,
                      $fid, $dmid, $key, $size, $trow->{classid});
    return $self->err_line("db_error") unless $rv;

    $dbh->do("DELETE FROM tempfile WHERE fid=?", undef, $fid);

    if (Mgd::update_fid_devcount($fid)) {
        return $self->ok_line();
    } else {
        # FIXME: handle this better
        return $self->err_line("db_error");
    }
}

sub cmd_delete {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # validate parameters
    my $dmid = $self->check_domain($args) or return 0;
    my $key = $args->{key};
    return $self->err_line("no_key") unless length($key);

    # get DB handle
    my $dbh = Mgd::get_dbh() or
        return $self->err_line("nodb");

    # is this fid still owned by this key?
    my $fid = $dbh->selectrow_array("SELECT fid FROM file WHERE dmid=? AND dkey=?",
                                    undef, $dmid, $key);
    return $self->err_line("unknown_key") unless $fid;

    $dbh->do("DELETE FROM file WHERE fid=?", undef, $fid);
    $dbh->do("REPLACE INTO file_to_delete SET fid=?", undef, $fid);

    return $self->ok_line();

}

sub cmd_list_fids {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # validate parameters
    my $fromfid = $args->{from}+0;
    my $tofid = $args->{to}+0;
    $tofid ||= ($fromfid + 100);
    $tofid = ($fromfid + 100)
        if $tofid > $fromfid + 100 ||
           $tofid < $fromfid;

    # get dbh to do the query
    my $dbh = Mgd::get_dbh() or
        return $self->err_line("nodb");
    my $rows = $dbh->selectall_hashref('SELECT fid, dmid, dkey, length, classid, devcount ' .
                                       'FROM file WHERE fid BETWEEN ? AND ?',
                                       'fid', undef, $fromfid, $tofid);
    return $self->err_line('failure') if $dbh->err || ! $rows;
    return $self->ok_line({ fid_count => 0 }) unless %$rows;

    # setup temporary storage of class/host
    my (%domains, %classes);

    # now iterate over our data rows and construct result
    my $ct = 0;
    my $ret = {};
    foreach my $fid (keys %$rows) {
        $ct++;
        my $r = $rows->{$fid};
        $ret->{"fid_${ct}_fid"} = $fid;
        $ret->{"fid_${ct}_domain"} = ($domains{$r->{dmid}} ||= Mgd::domain_name($r->{dmid}));
        $ret->{"fid_${ct}_class"} = ($classes{$r->{dmid}}{$r->{classid}} ||= Mgd::class_name($r->{dmid}, $r->{classid}));
        $ret->{"fid_${ct}_key"} = $r->{dkey};
        $ret->{"fid_${ct}_length"} = $r->{length};
        $ret->{"fid_${ct}_devcount"} = $r->{devcount};
    }
    $ret->{fid_count} = $ct;
    return $self->ok_line($ret);
}

sub cmd_list_keys {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # validate parameters
    my $dmid = $self->check_domain($args) or return 0;
    my ($prefix, $after, $limit) = ($args->{prefix}, $args->{after}, $args->{limit});
    return $self->err_line("no_key") unless $prefix;

    # now validate that after matches prefix
    return $self->err_line('after_mismatch')
        if $after && $after !~ /^$prefix/;

    # verify there are no % or \ characters
    return $self->err_line('invalid_chars')
        if $prefix =~ /[%\\]/;

    # escape underscores
    $prefix =~ s/_/\\_/g;

    # now fix the input... prefix always ends with a % so that it works
    # in a LIKE call, and after is either blank or something
    $prefix .= '%';
    $after ||= '';
    $limit ||= 1000;
    $limit += 0;

    # get DB handle
    my $dbh = Mgd::get_dbh() or
        return $self->err_line("nodb");

    # now select out our keys
    my $keys = $dbh->selectcol_arrayref
        ('SELECT dkey FROM file WHERE dmid = ? AND dkey LIKE ? AND dkey > ? ' .
         "ORDER BY dkey LIMIT $limit", undef, $dmid, $prefix, $after);

    # if we got nothing, say so
    return $self->err_line('none_match') unless $keys && @$keys;

    # construct the output and send
    my $ret = { key_count => 0, next_after => '' };
    foreach my $key (@$keys) {
        $ret->{key_count}++;
        $ret->{next_after} = $key
            if $key gt $ret->{next_after};
        $ret->{"key_$ret->{key_count}"} = $key;
    }
    return $self->ok_line($ret);
}

sub cmd_rename {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # validate parameters
    my $dmid = $self->check_domain($args) or return 0;
    my ($fkey, $tkey) = ($args->{from_key}, $args->{to_key});
    return $self->err_line("no_key") unless $fkey && $tkey;

    # get DB handle
    my $dbh = Mgd::get_dbh() or
        return $self->err_line("nodb");

    # rename the file
    my $ct = $dbh->do('UPDATE file SET dkey = ? WHERE dmid = ? AND dkey = ?',
                      undef, $tkey, $dmid, $fkey);
    return $self->err_line("key_exists") if $dbh->err;
    return $self->err_line("unknown_key") unless $ct > 0;

    return $self->ok_line();
}

sub cmd_get_hosts {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    Mgd::check_host_cache();

    my $ret = { hosts => 0 };
    while (my ($hostid, $row) = each %Mgd::cache_host) {
        next if defined $args->{hostid} && $hostid != $args->{hostid};

        $ret->{hosts}++;
        while (my ($key, $val) = each %$row) {
            # ignore things such as the netmask object
            next if ref $val;

            # must be regular data so copy it in
            $ret->{"host$ret->{hosts}_$key"} = $val;
        }
    }

    return $self->ok_line($ret);
}

sub cmd_get_devices {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $devs = Mgd::get_device_summary();

    my $ret = { devices => 0 };
    while (my ($devid, $row) = each %$devs) {
        next if defined $args->{devid} && $devid != $args->{devid};

        $ret->{devices}++;
        while (my ($key, $val) = each %$row) {
            $ret->{"dev$ret->{devices}_$key"} = $val;
        }
    }

    return $self->ok_line($ret);
}

sub cmd_create_device {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;
    my $devs = Mgd::get_device_summary();

    my $dbh = Mgd::get_dbh()
        or return $self->err_line("nodb");

    my $status = $args->{state} || "alive";
    return $self->err_line("invalid_state") unless $status =~ /^alive|down|readonly$/;

    my $devid = $args->{devid};
    return $self->err_line("invalid_devid") unless $devid && $devid =~ /^\d+$/;

    my $hostid;
    Mgd::check_host_cache();
    if ($args->{hostid} && $args->{hostid} =~ /^\d+$/) {
        $hostid = $args->{hostid};
        return $self->err_line("unknown_hostid") unless $Mgd::cache_host{$hostid};
    } elsif (my $host = $args->{hostname}) {
        while (my ($hid, $row) = each %Mgd::cache_host) {
            if ($row->{hostname} eq $host) {
                $hostid = $hid;
                last;
            }
        }
        return $self->err_line("unknown_host") unless $hostid;
    }

    $dbh->do("INSERT INTO device SET devid=?, hostid=?, status=?", undef,
             $devid, $hostid, $status);
    if ($dbh->err) {
        return $self->err_line("existing_devid");
    }
    return $self->ok_line;
}

sub cmd_create_domain {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $dbh = Mgd::get_dbh()
        or return $self->err_line("nodb");

    my $domain = $args->{domain};
    return $self->err_line('no_domain') unless length $domain;

    # FIXME: add some sort of authentication/limitation on this?

    my $dmid = Mgd::domain_id($domain);
    return $self->err_line('domain_exists') if $dmid;

    # get the max domain id
    my $maxid = $dbh->selectrow_array('SELECT MAX(dmid) FROM domain');
    $dbh->do('INSERT INTO domain (dmid, namespace) VALUES (?, ?)',
             undef, $maxid + 1, $domain);
    return $self->err_line('failure') if $dbh->err;

    # return the domain id we created
    return $self->ok_line({ domain => $domain });
}

sub cmd_delete_domain {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $domain = $args->{domain};
    return $self->err_line('no_domain') unless length $domain;

    # FIXME: add some sort of authentication/limitation on this?

    my $dmid = Mgd::domain_id($domain);
    return $self->err_line('domain_not_found') unless $dmid;

    # ensure it has no classes
    my $classes = Mgd::hostid_classes($dmid);
    return $self->err_line('failure') unless $classes;
    return $self->err_line('domain_not_empty') if %$classes;

    # and ensure it has no files (fast: key based)
    my $dbh = Mgd::get_dbh()
        or return $self->err_line("nodb");
    my $ct = $dbh->selectrow_array('SELECT COUNT(*) FROM file WHERE dmid = ?', undef, $dmid);
    return $self->err_line('failure') if $dbh->err;
    return $self->err_line('domain_has_files') if $ct;

    # all clear, nuke it
    $dbh->do("DELETE FROM domain WHERE dmid = ?", undef, $dmid);
    return $self->err_line('failure') if $dbh->err;

    # return the domain we nuked
    return $self->ok_line({ domain => $domain });
}

sub cmd_create_class {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $dbh = Mgd::get_dbh()
        or return $self->err_line("nodb");

    my $domain = $args->{domain};
    return $self->err_line('no_domain') unless length $domain;

    my $class = $args->{class};
    return $self->err_line('no_class') unless length $class;

    my $mindevcount = $args->{mindevcount}+0;
    return $self->err_line('invalid_mindevcount') unless $mindevcount > 0;

    # FIXME: add some sort of authentication/limitation on this?

    my $dmid = Mgd::domain_id($domain);
    return $self->err_line('no_domain') unless $dmid;

    my $cid = Mgd::class_id($dmid, $class);
    if ($args->{update}) {
        return $self->err_line('class_not_found') if ! $cid;
    } else {
        return $self->err_line('class_exists') if $cid;
    }

    # update or insert at this point
    if ($args->{update}) {
        # now replace the old class
        $dbh->do("REPLACE INTO class (dmid, classid, classname, mindevcount) VALUES (?, ?, ?, ?)",
                 undef, $dmid, $cid, $class, $mindevcount);
    } else {
        # get the max class id in this domain
        my $maxid = $dbh->selectrow_array
            ('SELECT MAX(classid) FROM class WHERE dmid = ?', undef, $dmid);

        # now insert the new class
        $dbh->do("INSERT INTO class (dmid, classid, classname, mindevcount) VALUES (?, ?, ?, ?)",
                 undef, $dmid, $maxid + 1, $class, $mindevcount);
    }
    return $self->err_line('failure') if $dbh->err;

    # return success
    return $self->ok_line({ class => $class, mindevcount => $mindevcount, domain => $domain });
}

sub cmd_update_class {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # simply passes through to create_class with update set
    $self->cmd_create_class({ %$args, update => 1 });
}

sub cmd_delete_class {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $domain = $args->{domain};
    return $self->err_line('no_domain') unless length $domain;

    my $class = $args->{class};
    return $self->err_line('no_class') unless length $domain;

    # FIXME: add some sort of authentication/limitation on this?

    my $dmid = Mgd::domain_id($domain);
    return $self->err_line('domain_not_found') unless $dmid;

    my $cid = Mgd::class_id($dmid, $class);
    return $self->err_line('class_not_found') unless $cid;

    # and ensure it has no files (fast: key based)
    my $dbh = Mgd::get_dbh()
        or return $self->err_line("nodb");
    my $ct = $dbh->selectrow_array('SELECT COUNT(*) FROM file WHERE dmid = ? AND classid = ?', undef, $dmid, $cid);
    return $self->err_line('failure') if $dbh->err;
    return $self->err_line('class_has_files') if $ct;

    # all clear, nuke it
    $dbh->do("DELETE FROM class WHERE dmid = ? AND classid = ?", undef, $dmid, $cid);
    return $self->err_line('failure') if $dbh->err;

    # return the class we nuked
    return $self->ok_line({ domain => $domain, class => $class });
}

sub cmd_create_host {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $dbh = Mgd::get_dbh()
        or return $self->err_line("nodb");

    my $host = $args->{host};
    return $self->err_line('no_host') unless $host;

    # unless update, require ip/port
    unless ($args->{update}) {
        return $self->err_line('no_ip') unless $args->{ip};
        return $self->err_line('no_port') unless $args->{port};
    }

    $args->{status} ||= 'down';
    return $self->err_line('unknown_state')
        unless $args->{status} =~ /^(?:alive|down|dead)$/;

    my $hid = Mgd::host_id($host);
    if ($args->{update}) {
        return $self->err_line('host_not_found') if ! $hid;
    } else {
        return $self->err_line('host_exists') if $hid;
    }

    # update or insert at this point
    if ($args->{update}) {
        # create an update list; basically we take our input arguments, map them
        # to the database columns, see if this argument was passed (so we don't
        # overwrite other things), and then quote the input and set it
        my %map = ( ip => 'hostip', port => 'http_port', getport => 'http_get_port',
                    altip => 'altip', altmask => 'altmask', root => 'remoteroot',
                    status => 'status', );
        my $set = join(', ', map { $map{$_} . " = " . $dbh->quote($args->{$_}) }
                             grep { exists $args->{$_} }
                             keys %map);

        # now do the update
        $dbh->do("UPDATE host SET $set WHERE hostid = ?", undef, $hid);
    } else {
        # get the max host id in use (FIXME: racy!)
        $hid = $dbh->selectrow_array('SELECT MAX(hostid) FROM host') + 1;

        # now insert the new host
        $dbh->do("INSERT INTO host (hostid, status, http_port, http_get_port, hostname, hostip, altip, altmask, remoteroot) " .
                 "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                 undef, $hid, map { $args->{$_} } qw(status port getport host ip altip altmask root));
    }
    return $self->err_line('failure') if $dbh->err;

    # force a host reload
    Mgd::invalidate_host_cache();

    # return success
    return $self->ok_line($Mgd::cache_host{$hid});
}

sub cmd_update_host {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # simply passes through to create_host with update set
    $self->cmd_create_host({ %$args, update => 1 });
}

sub cmd_delete_host {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $hostid = Mgd::host_id($args->{host})
        or return $self->err_line('unknown_host');

    my $dbh = Mgd::get_dbh()
        or return $self->err_line("nodb");

    my $dsum = Mgd::get_device_summary();
    foreach my $dev (values %$dsum) {
        return $self->err_line('host_not_empty')
            if $dev->{hostid} == $hostid && $dev->{status} ne "dead";
    }

    my $res = $dbh->do("DELETE FROM host WHERE hostid = ?", undef, $hostid);
    return $self->err_line('failure')
        unless $res;

    Mgd::invalidate_host_cache();
    return $self->ok_line;
}

sub cmd_get_domains {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $dbh = Mgd::get_dbh()
        or return $self->err_line("nodb");

    my $domains = $dbh->selectall_arrayref('SELECT dmid, namespace FROM domain');

    my $ret = {};
    my $outercount = 0;
    foreach my $row (@$domains) {
        $ret->{"domain" . ++$outercount} = $row->[1];

        # setup the return row for this set of classes
        my $classes = $dbh->selectall_arrayref
            ('SELECT classname, mindevcount FROM class WHERE dmid = ?', undef, $row->[0]);
        my $innercount = 0;
        foreach my $irow (@$classes) {
            $ret->{"domain${outercount}class" . ++$innercount . "name"} = $irow->[0];
            $ret->{"domain${outercount}class" . $innercount . "mindevcount"} = $irow->[1];
        }

        # record the default class and mindevcount
        $ret->{"domain${outercount}class" . ++$innercount . "name"} = 'default';
        $ret->{"domain${outercount}class" . $innercount . "mindevcount"} = $Mgd::default_mindevcount;

        $ret->{"domain${outercount}classes"} = $innercount;
    }
    $ret->{"domains"} = $outercount;

    return $self->ok_line($ret);
}

sub cmd_get_paths {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $key = $args->{key};

    return $self->err_line("no_key") unless length($key);

    # validate domain
    my $dmid = $self->check_domain($args) or return 0;

    # get DB handle
    my $dbh = Mgd::get_dbh() or
        return $self->err_line("nodb");

    my $filerow = Mgd::key_filerow($dbh, $dmid, $key);
    return $self->err_line("unknown_key") unless $filerow;

    my $fid = $filerow->{fid};
    my $dsum = Mgd::get_device_summary();

    my $ret = {
        paths => 0,
    };

    # is this fid still owned by this key?
    my $devids = $dbh->selectcol_arrayref("SELECT devid FROM file_on WHERE fid=?",
                                          undef, $fid) || [];

    # randomly weight the devices
    my @list = MogileFS::Util::weighted_list(map { [ $_, defined $dsum->{$_}->{weight} ?
                                                     $dsum->{$_}->{weight} : 100 ] } @$devids);

    # keep one partially-bogus path around just in case we have nothing else to send.
    my $backup_path;

    # construct result paths
    foreach my $devid (@list) {
        my $dev = $dsum->{$devid};
        next unless $dev && ($dev->{status} eq "alive" || $dev->{status} eq "readonly");

        my $path = Mgd::make_get_path($devid, $fid);
        my $currently_down =
            MogileFS->observed_state("host", $dev->{hostid}) eq "dead" ||
            MogileFS->observed_state("device", $dev->{devid}) eq "dead";

        if ($currently_down) {
            $backup_path = $path;
            next;
        }

        # only verify size one first one, and never verify if they've asked not to
        next unless
            $ret->{paths}        ||
            $args->{noverify}    ||
            Mgd::get_file_size($path, $dev) == $filerow->{length};

        my $n = ++$ret->{paths};
        $ret->{"path$n"} = $path;
        last if $n == 2;   # one verified, one likely seems enough for now.  time will tell.
    }

    # use our backup path if all else fails
    if ($backup_path && ! $ret->{paths}) {
        $ret->{paths} = 1;
        $ret->{path1} = $backup_path;
    }

    return $self->ok_line($ret);
}

sub cmd_set_weight {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # get database handle
    my $ret = {};
    my $dbh = Mgd::get_dbh()
        or return $self->err_line('nodb');

    # figure out what they want to do
    my ($host, $dev, $weight) = ($args->{host}, $args->{device}+0, $args->{weight}+0);
    return $self->err_line('bad_params')
        unless $host && $dev && $weight >= 0;

    # now get this device's current weight and host
    my ($realhost) =
        $dbh->selectrow_array('SELECT hostname FROM host, device ' .
                              'WHERE host.hostid = device.hostid AND device.devid = ?',
                              undef, $dev);

    # verify host is the same
    return $self->err_line('host_mismatch')
        unless $realhost eq $host;

    # update the weight in the database now
    $dbh->do('UPDATE device SET weight = ? WHERE devid = ?', undef, $weight, $dev);
    return $self->err_line('failure') if $dbh->err;

    # success, weight changed
    return $self->ok_line($ret);
}

sub cmd_set_state {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # get database handle
    my $ret = {};
    my $dbh = Mgd::get_dbh()
        or return $self->err_line('nodb');

    # figure out what they want to do
    my ($host, $dev, $state) = ($args->{host}, $args->{device}+0, $args->{state});
    return $self->err_line('bad_params')
        unless $host && $dev && ($state =~ /^(?:alive|down|dead|readonly)$/);

    # now get this device's current state and host
    my ($realhost, $curstate) =
        $dbh->selectrow_array('SELECT hostname, device.status FROM host, device ' .
                              'WHERE host.hostid = device.hostid AND device.devid = ?',
                              undef, $dev);

    # verify host is the same
    return $self->err_line('host_mismatch')
        unless $realhost eq $host;

    # make sure the destination state isn't too high
    return $self->err_line('state_too_high')
        if $curstate eq 'dead' && $state eq 'alive';

    # update the state in the database now
    $dbh->do('UPDATE device SET status = ? WHERE devid = ?', undef, $state, $dev);
    return $self->err_line('failure') if $dbh->err;

    # success, state changed
    return $self->ok_line($ret);
}

sub cmd_stats {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # get database handle
    my $ret = {};
    my $dbh = Mgd::get_dbh()
        or return $self->err_line('nodb');

    # get names of all domains and classes for use later
    my %classes;
    my $rows;

    $rows = $dbh->selectall_arrayref('SELECT class.dmid, namespace, classid, classname ' .
                                     'FROM domain, class WHERE class.dmid = domain.dmid');
    foreach my $row (@$rows) {
        $classes{$row->[0]}->{name} = $row->[1];
        $classes{$row->[0]}->{classes}->{$row->[2]} = $row->[3];
    }
    $classes{$_}->{classes}->{0} = 'default'
        foreach keys %classes;

    # get host and device information with device status
    my %devices;
    $rows = $dbh->selectall_arrayref('SELECT device.devid, hostname, device.status ' .
                                     'FROM device, host WHERE device.hostid = host.hostid');
    foreach my $row (@$rows) {
        $devices{$row->[0]}->{host} = $row->[1];
        $devices{$row->[0]}->{status} = $row->[2];
    }

    # if they want replication counts, or didn't specify what they wanted
    if ($args->{replication} || $args->{all}) {
        # replication stats
        my $stats = $dbh->selectall_arrayref('SELECT dmid, classid, devcount, COUNT(devcount) FROM file GROUP BY 1, 2, 3');
        my $count = 0;
        foreach my $stat (@$stats) {
            $count++;
            $ret->{"replication${count}domain"} = $classes{$stat->[0]}->{name};
            $ret->{"replication${count}class"} = $classes{$stat->[0]}->{classes}->{$stat->[1]};
            $ret->{"replication${count}devcount"} = $stat->[2];
            $ret->{"replication${count}files"} = $stat->[3];
        }
        $ret->{"replicationcount"} = $count;
    }

    # file statistics (how many files there are and in what domains/classes)
    if ($args->{files} || $args->{all}) {
        my $stats = $dbh->selectall_arrayref('SELECT dmid, classid, COUNT(classid) FROM file GROUP BY 1, 2');
        my $count = 0;
        foreach my $stat (@$stats) {
            $count++;
            $ret->{"files${count}domain"} = $classes{$stat->[0]}->{name};
            $ret->{"files${count}class"} = $classes{$stat->[0]}->{classes}->{$stat->[1]};
            $ret->{"files${count}files"} = $stat->[2];
        }
        $ret->{"filescount"} = $count;
    }

    # device statistics (how many files are on each device)
    if ($args->{devices} || $args->{all}) {
        my $stats = $dbh->selectall_arrayref('SELECT devid, COUNT(devid) FROM file_on GROUP BY 1');
        my $count = 0;
        foreach my $stat (@$stats) {
            $count++;
            $ret->{"devices${count}id"} = $stat->[0];
            $ret->{"devices${count}host"} = $devices{$stat->[0]}->{host};
            $ret->{"devices${count}status"} = $devices{$stat->[0]}->{status};
            $ret->{"devices${count}files"} = $stat->[1];
        }
        $ret->{"devicescount"} = $count;
    }

    # now fid statitics
    if ($args->{fids} || $args->{all}) {
        my $max = $dbh->selectrow_array('SELECT MAX(fid) FROM file');
        $ret->{"fidmax"} = $max;
    }

    # FIXME: DO! add other stats

    return $self->ok_line($ret);
}

sub cmd_noop {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;
    return $self->ok_line;
}

sub ok_line {
    my MogileFS::Worker::Query $self = shift;

    my $delay = '';
    if ($self->{querystarttime}) {
        $delay = sprintf("%.4f ", Time::HiRes::tv_interval([ $self->{querystarttime} ]));
        $self->{querystarttime} = undef;
    }

    my $id = defined $self->{reqid} ? "$self->{reqid} " : '';

    my $args = shift;
    my $argline = join('&', map { eurl($_) . "=" . eurl($args->{$_}) } keys %$args);
    $self->send_to_parent("${id}${delay}OK $argline");
    return 1;
}

# first argument: error code.
# second argument: optional error text.  text will be taken from code if no text provided.
sub err_line {
    my MogileFS::Worker::Query $self = shift;
    my $err_code = shift;
    my $err_text = shift || {
        'after_mismatch' => "Pattern does not match the after-value?",
        'bad_params' => "Invalid parameters to command; please see documentation",
        'class_exists' => "That class already exists in that domain",
        'class_has_files' => "Class still has files, uanble to delete",
        'class_not_found' => "Class not found",
        'domain_has_files' => "Domain still has files, uanble to delete",
        'domain_exists' => "That domain already exists",
        'domain_not_empty' => "Domain still has classes, unable to delete",
        'domain_not_found' => "Domain not found",
        'failure' => "Operation failed",
        'host_exists' => "That host already exists",
        'host_mismatch' => "The device specified doesn't belong to the host specified",
        'host_not_empty' => "Unable to delete host; it contains devices still",
        'host_not_found' => "Host not found",
        'invalid_chars' => "Patterns must not contain backslashes (\\) or percent signs (%).",
        'invalid_mindevcount' => "The mindevcount must be at least 1",
        'key_exists' => "Target key name already exists; can't overwrite.",
        'no_class' => "No class provided",
        'no_domain' => "No domain provided",
        'no_host' => "No host provided",
        'no_ip' => "IP required to create host",
        'no_port' => "Port required to create host",
        'none_match' => "No keys match that pattern and after-value (if any).",
        'state_too_high' => "Status cannot go from dead to alive; must use down",
        'unknown_command' => "Unknown server command",
        'unknown_host' => "Host not found",
        'unknown_state' => "Invalid/unknown state",
        'unreg_domain' => "Domain name invalid/not found",
    }->{$err_code};

    my $delay = '';
    if ($self->{querystarttime}) {
        $delay = sprintf("%.4f ", Time::HiRes::tv_interval([ $self->{querystarttime} ]));
        $self->{querystarttime} = undef;
    }

    my $id = defined $self->{reqid} ? "$self->{reqid} " : '';

    $self->send_to_parent("${id}${delay}ERR $err_code " . eurl($err_text));
    return 0;
}

sub eurl
{
    my $a = $_[0];
    $a =~ s/([^a-zA-Z0-9_\,\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}

sub decode_url_args
{
    my $a = shift;
    my $buffer = ref $a ? $a : \$a;
    my $ret = {};

    my $pair;
    my @pairs = split(/&/, $$buffer);
    my ($name, $value);
    foreach $pair (@pairs)
    {
        ($name, $value) = split(/=/, $pair);
        $value =~ tr/+/ /;
        $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $name =~ tr/+/ /;
        $name =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $ret->{$name} .= $ret->{$name} ? "\0$value" : $value;
    }
    return $ret;
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End: