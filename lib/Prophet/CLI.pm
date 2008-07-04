package Prophet::CLI;
use Moose;
use MooseX::ClassAttribute;

has app_class => (
        is => 'rw',
        isa => 'Str', # 'Prophet::App',
        default => 'Prophet::App'
);

has record_class => (
        is => 'rw',
        isa => 'Str',# 'Prophet::Record',
        default => 'Prophet::Record'
);

has app_handle => (
        is => 'rw',
        isa => 'Prophet::App',
        lazy => 1,
        default => sub { $_[0]->app_class->require; $_[0]->app_class->new() }
);



has uuid => (   # this is the uuid set by the user from the commandline
    is => 'rw',
    isa => 'Str'
    );

has type => (   # this is the type set by the user from the commandline
    is => 'rw',
    isa => 'Str'
    );


has primary_commands => ( # the commadns the user executes from the commandline
    is => 'rw',
    isa => 'ArrayRef'
    );

has args => (
    metaclass  => 'Collection::Hash',
    is         => 'rw',
    isa        => 'HashRef',
    default    => sub { {} },
    provides   => {
        set    => 'set_arg',
        get    => 'arg',
        exists => 'has_arg',
        delete => 'delete_arg',
    },
);

use Prophet;
use Prophet::Record;
use Prophet::Collection;
use Prophet::Replica;


=head2 _record_cmd

handles the subcommand for a particular type

=cut

our %CMD_MAP = (
    ls   => 'search',
    new  => 'create',
    edit => 'update',
    rm   => 'delete',
    del  => 'delete',
    list => 'search'
);


sub _get_cmd_obj {
    my $self = shift;

    my @commands = map { exists $CMD_MAP{$_} ? $CMD_MAP{$_} : $_ } @{ $self->primary_commands };

    my @possible_classes;

    my @to_try = @commands;

    while (@to_try) {
        my $cmd = $self->app_class . "::CLI::Command::" . join( '::', map { ucfirst lc $_ } @to_try );    # App::SD::CLI::Command::Ticket::Comment::List
        push @possible_classes, $cmd;
        shift @to_try;                                                                                    # throw away that top-level "Ticket" option
    }

    my @extreme_fallback_commands = (
        $self->app_class . "::CLI::Command::" . ucfirst( lc( $commands[-1] ) ),                           # App::SD::CLI::Command::List
        "Prophet::CLI::Command::" . ucfirst( lc $commands[-1] ),                                          # Prophet::CLI::Command::List
        $self->app_class . "::CLI::Command::NotFound",
        "Prophet::CLI::Command::NotFound"
    );

    my $class;

    for my $try ( @possible_classes, @extreme_fallback_commands ) {
        $class = $self->_try_to_load_cmd_class($try);
        last if $class;
    }

    die "I don't know how to parse '" . join( " ", @{ $self->primary_commands } ) . "'. Are you sure that's a valid command?" unless ($class);

    my $command_obj = $class->new(
        {   cli      => $self,
            commands => $self->primary_commands,
            type     => $self->type,
            uuid     => $self->uuid
        }
    );
    return $command_obj;
}

sub _try_to_load_cmd_class {
    my $self = shift;
    my $class = shift;
    Prophet::App->require_module($class);
    warn "trying out " .$class;
    no strict 'refs';
    warn join(',', @{$class.'::ISA'});
    return $class if ( $class->isa('Prophet::CLI::Command') );
    warn "aw. not it";
    return undef;
}

=head2 parse_args

This routine pulls arguments passed on the command line out of ARGV and sticks them in L</args>. The keys have leading "--" stripped.


=cut

sub parse_args {
    my $self = shift;

    my @primary;
    push @primary, shift @ARGV while ( $ARGV[0] &&  $ARGV[0] =~ /^\w+$/ && $ARGV[0] !~ /^--/ );


    $self->primary_commands( \@primary );

    while (my $name = shift @ARGV) { 
        die "$name doesn't look like --prop-name" if ( $name !~ /^--/ );
        my $val;

        ($name,$val)= split(/=/,$name,2) if ($name =~/=/);
        $name =~ s/^--//;
        $self->set_arg($name => ($val || shift @ARGV));
    }

}

=head2 set_type_and_uuid

When working with individual records, it is often the case that we'll be expecting a --type argument and then a mess of other key-value pairs. 

=cut

sub set_type_and_uuid {
    my $self = shift;

    if (my $id = $self->delete_arg('id')) {
        if ($id =~ /^(\d+)$/) { 
        $self->set_arg(luid => $id);
        } else { 
        $self->set_arg(uuid => $id);

        }

    }

    if ( my $uuid = $self->delete_arg('uuid')) {
        $self->uuid($uuid);
    }
    elsif ( my $luid = $self->delete_arg('luid')) {
        my $uuid = $self->app_handle->handle->find_uuid_by_luid(luid => $luid);
        die "I have no UUID mapped to the local id '$luid'\n" if !defined($uuid);
        $self->uuid($uuid);
    }
    if ( my $type = $self->delete_arg('type') ) {
        $self->type($type);
    } elsif($self->primary_commands->[-2]) {
        $self->type($self->primary_commands->[-2]); 
    }
}

=head2 args [$ARGS]

Returns a reference to the key-value pairs passed in on the command line

If passed a hashref, sets the args to taht;

=cut

sub run_one_command {
    my $self = shift;
    $self->parse_args();
    $self->set_type_and_uuid();
    if ( my $cmd_obj = $self->_get_cmd_obj() ) {
        $cmd_obj->run();
    }
}

=head2 invoke [outhandle], ARGV

Run the given command. If outhandle is true, select that as the file handle
for the duration of the command.

=cut

sub invoke {
    my ($self, $output, @args) = @_;
    my $ofh;

    local *ARGV = \@args;
    $ofh = select $output if $output;
    my $ret = eval { $self->run_one_command };
    warn $@ if $@;
    select $ofh if $ofh;
    return $ret;
}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::RecordCommand;
use Moose::Role;

has type => (
    is => 'rw',
    isa => 'Str',
    required => 0
);

has uuid => (
    is => 'rw',
    isa => 'Str',
    required => 0
);

has record_class => (
    is => 'rw',
    isa => 'Prophet::Record',
);


sub _get_record {
    my $self = shift;
     my $args = { handle => $self->cli->app_handle->handle, type => $self->type };
    if (my $class =  $self->record_class ) {
        Prophet::App->require_module($class);
        return $class->new( $args);
    } elsif ( $self->type ) {
        return $self->_type_to_record_class( $self->type )->new($args);
    } else { Carp::confess("I was asked to get a record object, but I have neither a type nor a record class")}

}

sub _type_to_record_class {
    my $self = shift;
    my $type = shift;
    my $try = $self->cli->app_class . "::Model::" . ucfirst( lc($type) );
    Prophet::App->require_module($try);    # don't care about fails
    return $try if ( $try->isa('Prophet::Record') );

    $try = $self->cli->app_class . "::Record";
    Prophet::App->require_module($try);    # don't care about fails
    return $try if ( $try->isa('Prophet::Record') );
    return 'Prophet::Record';
}

no Moose::Role;

package Prophet::CLI::Command;
use Moose;

has cli => (
    is => 'rw',
    isa => 'Prophet::CLI',
    weak_ref => 1,
    handles => [qw/args set_arg arg has_arg delete_arg app_handle/],
);

sub fatal_error {
    my $self   = shift;
    my $reason = shift;
    die $reason . "\n";

}


=head2 edit_text [text] -> text

Filters the given text through the user's C<$EDITOR> using
L<Proc::InvokeEditor>.

=cut

sub edit_text {
    my $self = shift;
    my $text = shift;

    require Proc::InvokeEditor;
    return scalar Proc::InvokeEditor->edit($text);
}

=head2 edit_hash hashref -> hashref

Filters the hash through the user's C<$EDITOR> using L<Proc::InvokeEditor>.

No validation is done on the input or output.

=cut

sub edit_hash {
    my $self = shift;
    my $hash = shift;

    my $input = join "\n", map { "$_: $hash->{$_}\n" } keys %$hash;
    my $output = $self->edit_text($input);

    my $filtered = {};
    while ($output =~ m{^(\S+?):\s*(.*)$}mg) {
        $filtered->{$1} = $2;
    }

    return $filtered;
}

=head2 edit_args [arg], defaults -> hashref

Returns a hashref of the command arguments mixed in with any default arguments.
If the "arg" argument is specified, (default "edit", use C<undef> if you only want default arguments), then L</edit_hash> is
invoked on the argument list.

=cut

sub edit_args {
    my $self = shift;
    my $arg  = shift || 'edit';

    my $edit_hash;
    if ($self->has_arg($arg)) {
        $self->delete_arg($arg);
        $edit_hash = 1;
    }

    my %args;
    if (@_ == 1) {
        %args = (%{ $self->args }, %{ $_[0] });
    }
    else {
        %args = (%{ $self->args }, @_);
    }

    if ($edit_hash) {
        return $self->edit_hash(\%args);
    }

    return \%args;
}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::Command::Create;
use Moose;
extends 'Prophet::CLI::Command';
with 'Prophet::CLI::RecordCommand';
has +uuid => ( required => 0);

sub run {
    my $self   = shift;
    my $record = $self->_get_record;
    my ($val, $msg) = $record->create( props => $self->edit_args );
    if (!$val) { 
        warn $msg ."\n";
    }
    if (!$record->uuid) {
        warn "Failed to create " . $record->record_type . "\n";
        return;
    }

    print "Created " . $record->record_type . " " . $record->luid . " (".$record->uuid.")"."\n";

}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::Command::Search;
use Moose;
extends 'Prophet::CLI::Command';
with 'Prophet::CLI::RecordCommand';
has +uuid => ( required => 0);

sub get_collection_object {
    my $self = shift;

    my $class = $self->_get_record->collection_class;
    Prophet::App->require_module($class);
    my $records = $class->new(
        handle => $self->app_handle->handle,
        type   => $self->type
    );

    return $records;
}

sub get_search_callback {
    my $self = shift;

    if ( my $regex = $self->arg('regex') ) {
            return sub {
                my $item  = shift;
                my $props = $item->get_props;
                map { return 1 if $props->{$_} =~ $regex } keys %$props;
                return 0;
            }
    } else {
        return sub {1}
    }
}
sub run {
    my $self = shift;

    my $records = $self->get_collection_object();
    my $search_cb = $self->get_search_callback();
    $records->matching($search_cb);

    for ( sort { $a->uuid cmp $b->uuid } $records->items ) {
        if ( $_->summary_props ) {
            print $_->format_summary . "\n";
        } else {
            # XXX OLD HACK TO MAKE TESTS PASS
            printf( "%s %s %s \n", $_->uuid, $_->prop('summary') || "(no summary)", $_->prop('status')  || '(no status)' );
        }
    }
}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::Command::Update;
use Moose;
extends 'Prophet::CLI::Command';
with 'Prophet::CLI::RecordCommand';

sub edit_record {
    my $self   = shift;
    my $record = shift;

    if ($self->has_arg('edit')) {
        my $props = $record->get_props;
        return $self->edit_hash($props);
    }
    else {
        return $self->args;
    }
}

sub run {
    my $self = shift;

    my $record = $self->_get_record;
    $record->load( uuid => $self->uuid );
    my $result = $record->set_props( props => $self->edit_record($record) );
    if ($result) {
        print $record->type . " " . $record->uuid . " updated.\n";

    } else {
        print "SOMETHING BAD HAPPENED "
            . $record->type . " "
            . $record->uuid
            . " not updated.\n";

    }
}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::Command::Delete;
use Moose;
extends 'Prophet::CLI::Command';
with 'Prophet::CLI::RecordCommand';
sub run {
    my $self = shift;

    my $record = $self->_get_record;
    $record->load( uuid => $self->uuid )
        || $self->fatal_error("I couldn't find the record " . $self->uuid);
    if ( $record->delete ) {
        print $record->type . " " . $record->uuid . " deleted.\n";
    } else {
        print $record->type . " " . $record->uuid . "could not be deleted.\n";
    }

}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::Command::Show;
use Moose;
extends 'Prophet::CLI::Command';
with 'Prophet::CLI::RecordCommand';


sub run {
    my $self = shift;

    my $record = $self->_get_record;
    if ( !$record->load( uuid => $self->uuid ) ) {
        print "Record not found\n";
        return;
    }
    print "id: ".$record->luid." (" .$record->uuid.")\n";
    my $props = $record->get_props();
    for ( keys %$props ) {
        print $_. ": " . $props->{$_} . "\n";
    }

}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::Command::Merge;
use Moose;
extends 'Prophet::CLI::Command';

sub run {

    my $self = shift;

    my $source = Prophet::Replica->new( { url => $self->arg('from') } );
    my $target = Prophet::Replica->new( { url => $self->arg('to') } );

    $target->import_resolutions_from_remote_replica( from => $source );

    $self->_do_merge( $source, $target );

    print "Merge complete.\n";
}

sub _do_merge {
    my ( $self, $source, $target ) = @_;
    if ( $target->uuid eq $source->uuid ) {
        $self->fatal_error(
                  "You appear to be trying to merge two identical replicas. "
                . "Either you're trying to merge a replica to itself or "
                . "someone did a bad job cloning your database" );
    }

    my $prefer = $self->arg('prefer') || 'none';

    if ( !$target->can_write_changesets ) {
        $self->fatal_error( $target->url
                . " does not accept changesets. Perhaps it's unwritable or something"
        );
    }

    $target->import_changesets(
        from  => $source,
        resdb => $self->app_handle->resdb_handle,
        $ENV{'PROPHET_RESOLVER'}
        ? ( resolver_class => 'Prophet::Resolver::' . $ENV{'PROPHET_RESOLVER'} )
        : ( (   $prefer eq 'to'
                ? ( resolver_class => 'Prophet::Resolver::AlwaysTarget' )
                : ()
            ),
            (   $prefer eq 'from'
                ? ( resolver_class => 'Prophet::Resolver::AlwaysSource' )
                : ()
            )
        )
    );

}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::Command::Push;
use Moose;
extends 'Prophet::CLI::Command::Merge';

sub run {
    my $self = shift;

    my $source_me    = $self->app_handle->handle;
    my $other        = shift @ARGV;
    my $source_other = Prophet::Replica->new( { url => $other } );
    my $resdb        = $source_me->import_resolutions_from_remote_replica(
        from => $source_other );

    $self->_do_merge( $source_me, $source_other );
}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::Command::Export;
use Moose;
extends 'Prophet::CLI::Command';

sub run {
    my $self = shift;

    $self->app_handle->handle->export_to( path => $self->arg('path') );
}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::Command::Pull;
use Moose;
extends 'Prophet::CLI::Command::Merge';

sub run {

    my $self         = shift;
    my $other        = shift @ARGV;
    my $source_other = Prophet::Replica->new( { url => $other } );
    $self->app_handle->handle->import_resolutions_from_remote_replica(
        from => $source_other );

    $self->_do_merge( $source_other, $self->app_handle->handle );

}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::Command::Server;
use Moose;
extends 'Prophet::CLI::Command';

sub run {

    my $self = shift;

    require Prophet::Server::REST;
    my $server = Prophet::Server::REST->new( $self->arg('port') || 8080 );
    $server->prophet_handle( $self->app_handle->handle );
    $server->run;
}

__PACKAGE__->meta->make_immutable;
no Moose;

package Prophet::CLI::Command::NotFound;
use Moose;
extends 'Prophet::CLI::Command';

sub run {
    my $self = shift;
    $self->fatal_error( "The command you ran could not be found. Perhaps running '$0 help' would help?" );
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
