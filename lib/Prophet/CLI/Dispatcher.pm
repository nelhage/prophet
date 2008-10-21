package Prophet::CLI::Dispatcher;
use Path::Dispatcher::Declarative -base;
use Moose;
with 'Prophet::CLI::Parameters';

use Prophet::CLI;

has dispatching_on => (
    is       => 'rw',
    isa      => 'ArrayRef',
    required => 1,
);

has record => (
    is            => 'rw',
    isa           => 'Prophet::Record',
    documentation => 'If the command operates on a record, it will be stored here.',
);

on server => sub {
    my $self = shift;
    my $server = $self->setup_server;
    $server->run;
};

on [ [ 'create', 'new' ] ] => sub {
    my $self   = shift;
    my $record = $self->context->_get_record_object;

    my ($val, $msg) = $record->create(props => $self->cli->edit_props);

    if (!$val) {
        warn "Unable to create record: " . $msg . "\n";
    }
    if (!$record->uuid) {
        warn "Failed to create " . $record->record_type . "\n";
        return;
    }

    $self->record($record);

    printf "Created %s %s (%s)\n",
        $record->record_type,
        $record->luid,
        $record->uuid;
};

on [ [ 'delete', 'del', 'rm' ] ] => sub {
    my $self = shift;

    $self->context->require_uuid;
    my $record = $self->context->_load_record;
    my $deleted = $record->delete;

    if ($deleted) {
        print $record->type . " " . $record->uuid . " deleted.\n";
    } else {
        print $record->type . " " . $record->uuid . " could not be deleted.\n";
    }

};

on [ [ 'update', 'edit' ] ] => sub {
    my $self = shift;

    $self->context->require_uuid;
    my $record = $self->context->_load_record;

    my $new_props = $self->cli->edit_record($record);
    my $updated = $record->set_props( props => $new_props );

    if ($updated) {
        print $record->type . " " . $record->luid . " (".$record->uuid.")"." updated.\n";

    } else {
        print "SOMETHING BAD HAPPENED "
            . $record->type . " "
            . $record->luid . " ("
            . $record->uuid
            . ") not updated.\n";
    }
};

on [ [ 'show', 'display' ] ] => sub {
    my $self = shift;

    $self->context->require_uuid;
    my $record = $self->context->_load_record;

    print $self->cli->stringify_props(
        record  => $record,
        batch   => $self->context->has_arg('batch'),
        verbose => $self->context->has_arg('verbose'),
    );
};

on config => sub {
    my $self = shift;

    my $config = $self->cli->config;

    print "Configuration:\n\n";
    my @files = @{$config->config_files};
    if (!scalar @files) {
        print $self->no_config_files;
        return;
    }

    print "Config files:\n\n";
    for my $file (@files) {
        print "$file\n";
    }

    print "\nYour configuration:\n\n";
    for my $item ($config->list) {
        print $item ." = ".$config->get($item)."\n";
    }
};

on export => sub {
    my $self = shift;
    $self->cli->handle->export_to( path => $self->context->arg('path') );
};

on history => sub {
    my $self = shift;

    $self->context->require_uuid;
    my $record = $self->context->_load_record;
    $self->record($record);
    print $record->history_as_string;
};

on log => sub {
    my $self   = shift;
    my $handle = $self->cli->handle;
    my $newest = $self->context->arg('last') || $handle->latest_sequence_no;
    my $start  = $newest - ( $self->context->arg('count') || '20' );
    $start = 0 if $start < 0;

    $handle->traverse_changesets(
        after    => $start,
        callback => sub {
            my $changeset = shift;
            $self->changeset_log($changeset);
        },
    );

};

on merge => sub {
    my $self = shift;

    require Prophet::CLI::Command::Merge;
    Prophet::CLI::Command::Merge->new(cli => $self->cli)->run;
};

on push => sub {
    my $self = shift;

    die "Please specify a --to.\n" if !$self->context->has_arg('to');

    $self->context->set_arg(from => $self->cli->app_handle->default_replica_type.":file://".$self->cli->handle->fs_root);
    $self->context->set_arg(db_uuid => $self->cli->handle->db_uuid);
    run('merge', $self, @_);
};

on pull => sub {
    my $self = shift;
    my @from;

    my $from = $self->context->arg('from');

    $self->context->set_arg(db_uuid => $self->cli->handle->db_uuid)
        unless $self->context->has_arg('db_uuid');

    my %previous_sources = $self->_read_cached_upstream_replicas;
    push @from, $from
        if $from
        && (!$self->context->has_arg('all') || !$previous_sources{$from});

    push @from, keys %previous_sources if $self->context->has_arg('all');

    my @bonjour_replicas = $self->find_bonjour_replicas;

    die "Please specify a --from, --local or --all.\n"
        unless $from
            || $self->context->has_arg('local')
            || $self->context->has_arg('all');

    $self->context->set_arg(to => $self->cli->app_handle->default_replica_type
            . ":file://"
            . $self->cli->handle->fs_root );

    for my $from ( @from, @bonjour_replicas ) {
        print "Pulling from $from\n";
        #if $self->context->has_arg('all') || $self->context->has_arg('local');
        $self->context->set_arg(from => $from);
        run("merge", $self, @_);
        print "\n";
    }

    if ( $from && !exists $previous_sources{$from} ) {
        $previous_sources{$from} = 1;
        $self->_write_cached_upstream_replicas(%previous_sources);
    }
};

on shell => sub {
    my $self = shift;

    require Prophet::CLI::Shell;
    my $shell = Prophet::CLI::Shell->new(
        cli => $self->cli,
    );
    $shell->run;
};

on publish => sub {
    my $self = shift;

    die "Please specify a --to.\n" unless $self->context->has_arg('to');
    # set the temp directory where we will do all of our work, which will be
    # published via rsync
    require File::Temp;
    $self->context->set_arg(path => File::Temp::tempdir(CLEANUP => 1));

    my $export_html = $self->context->has_arg('html');
    my $export_replica = $self->context->has_arg('replica');

    # if the user specifies nothing, then publish the replica
    $export_replica = 1 if !$export_html;

    # if we have the html argument, populate the tempdir with rendered templates
    $self->export_html() if $export_html;

    # otherwise, do the normal prophet export this replica
    run("export", $self, @_) if $export_replica;

    # the tempdir is populated, now publish it
    my $from = $self->context->arg('path');
    my $to   = $self->context->arg('to');

    $self->publish_dir(
        from => $from,
        to   => $to,
    );

    print "Publish complete.\n";
};

on [ ['search', 'list', 'ls' ] ] => sub {
    my $self = shift;

    my $records = $self->context->get_collection_object;
    my $search_cb = $self->context->get_search_callback;
    $records->matching($search_cb);

    $self->display_collection($records);
};

sub fatal_error {
    my $self   = shift;
    my $reason = shift;

    die $reason . "\n";
}

sub setup_server {
    my $self = shift;
    require Prophet::Server;
    my $server = Prophet::Server->new($self->context->arg('port') || 8080);
    $server->app_handle($self->context->app_handle);
    $server->setup_template_roots;
    return $server;
}

sub no_config_files {
    my $self = shift;
    return "No configuration files found. "
         . " Either create a file called 'prophetrc' inside of "
         . $self->cli->handle->fs_root
         . " or set the PROPHET_APP_CONFIG environment variable.\n\n";
}

sub changeset_log {
    my $self      = shift;
    my $changeset = shift;
    print $changeset->as_string(
        change_header => sub {
            my $change = shift;
            $self->change_header($change);
        }
    );
}

sub change_header {
    my $self   = shift;
    my $change = shift;
    return
          " # "
        . $change->record_type . " "
        . $self->cli->handle->find_or_create_luid(
        uuid => $change->record_uuid )
        . " ("
        . $change->record_uuid . ")\n";
}

=head2 find_bonjour_replicas

Probes the local network for bonjour replicas if the local arg is specified.

Returns a list of found replica URIs.

=cut

sub find_bonjour_replicas {
    my $self = shift;
    my @bonjour_replicas;
    if ( $self->context->has_arg('local') ) {
        Prophet::App->try_to_require('Net::Bonjour');
        if ( Prophet::App->already_required('Net::Bonjour') ) {
            print "Probing for local database replicas with Bonjour\n";
            my $res = Net::Bonjour->new('prophet');
            $res->discover;
            foreach my $entry ( $res->entries ) {
                if ( $entry->name eq $self->context->arg('db_uuid') ) {
                    print "Found a database replica on " . $entry->hostname."\n";
                    my $uri = URI->new();
                    $uri->scheme( 'http' );
                    $uri->host($entry->hostname);
                    $uri->port( $entry->port );
                    $uri->path('replica/');
                    push @bonjour_replicas,  $uri->canonical.""; #scalarize
                }
            }
        }

    }
    return @bonjour_replicas;
}

=head2 _read_cached_upstream_replicas

Returns a hash containing url => 1 pairs, where the URLs are the replicas that
have been previously pulled from.

=cut

sub _read_cached_upstream_replicas {
    my $self = shift;
    return map { $_ => 1 } $self->cli->handle->_read_cached_upstream_replicas;
}

=head2 _write_cached_upstream_replicas %replicas

Writes the replica URLs given in C<keys %replicas> to the current Prophet
repository's upstream replica cache (these replicas will be pulled from when a
user specifies --all).

=cut

sub _write_cached_upstream_replicas {
    my $self  = shift;
    my %repos = @_;
    return $self->cli->handle->_write_cached_upstream_replicas(keys %repos);
}

sub export_html {
	my $self = shift;

    require Path::Class;
    my $path = Path::Class::dir($self->context->arg('path'));

    # if they specify both html and replica, then stick rendered templates
    # into a subdirectory. if they specify only html, assume they really
    # want to publish directly into the specified directory
    if ($self->context->has_arg('replica')){
        $path = $path->subdir('html');
        $path->mkpath;
    }

    $self->render_templates_into($path);
}

sub view_classes { [ 'Prophet::Server::View' ] }

# helper methods for rendering templates
sub render_templates_into {
    my $self = shift;
    my $dir  = shift;

    my $classes = $self->view_classes;
    Prophet::App->require($_) for @$classes;
    Template::Declare->init(roots => $classes);

    # allow user to specify a specific type to render
    my @types = $self->types_to_render;

    for my $type (@types) {
        my $subdir = $dir->subdir($type);
        $subdir->mkpath;

        my $records = $self->context->get_collection_object(type => $type);
        $records->matching(sub { 1 });

        my $fh = $subdir->file('index.html')->openw;
        print { $fh } Template::Declare->show('record_table' => $records);
        close $fh;

        for my $record ($records->items) {
            my $fh = $subdir->file($record->uuid . '.html')->openw;
            print { $fh } Template::Declare->show('record' => $record);
        }
    }
}

sub should_render_type {
    my $self = shift;
    my $type = shift;

    # should we skip all _private types?
    return 0 if $type eq '_merge_tickets';

    return 1;
}

sub types_to_render {
    my $self = shift;

    return grep { $self->should_render_type($_) }
           @{ $self->cli->handle->list_types };
}

sub publish_dir {
    my $self = shift;
    my %args = @_;

    my @args;
    push @args, '--recursive';
    push @args, '--verbose' if $self->context->has_arg('verbose');

    push @args, '--';

    require Path::Class;
    push @args, Path::Class::dir($args{from})->children;

    push @args, $args{to};

    my $rsync = $ENV{RSYNC} || "rsync";
    my $ret = system($rsync, @args);

    if ($ret == -1) {
        die "You must have 'rsync' installed to use this command.

If you have rsync but it's not in your path, set environment variable \$RSYNC to the absolute path of your rsync executable.\n";
    }

    return $ret;
}

sub display_collection {
    my $self = shift;
    my $items = shift;

    for (sort { $a->luid <=> $b->luid } @$items) {
        print $_->format_summary . "\n";
    }
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

