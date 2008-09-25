package Prophet::CLI;
use Moose;
use MooseX::ClassAttribute;

use Prophet;
use Prophet::Replica;
use Prophet::CLI::Dispatcher;
use Prophet::CLIContext;

use List::Util 'first';

has app_class => (
    is      => 'rw',
    isa     => 'ClassName',
    default => 'Prophet::App',
);

has record_class => (
    is      => 'rw',
    isa     => 'ClassName',
    lazy    => 1,
    default => 'Prophet::Record',
);

has app_handle => (
    is      => 'rw',
    isa     => 'Prophet::App',
    lazy    => 1,
    handles => [qw/handle resdb_handle config/],
    default => sub {
        return $_[0]->app_class->new;
    },
);


has context => (
    is => 'rw',
    isa => 'Prophet::CLIContext',
    lazy => 1,
    default => sub {
        return Prophet::CLIContext->new( app_handle => shift->app_handle);
    }

);

has interactive_shell => ( 
    is => 'rw',
    isa => 'Bool',
    default => sub { 0}
);


=head2 dispatcher_class -> Class

Returns the dispatcher class used to dispatch command lines. You'll want to
override this in your subclass.

=cut

sub dispatcher_class { "Prophet::CLI::Dispatcher" }

=head2 run_one_command

Runs a command specified by commandline arguments given in an
ARGV-like array of argumnents and key value pairs . To use in a
commandline front-end, create a L<Prophet::CLI> object and pass in
your main app class as app_class, then run this routine.

Example:

 my $cli = Prophet::CLI->new({ app_class => 'App::SD' });
 $cli->run_one_command(@ARGV);

=cut

sub run_one_command {
    my $self = shift;
    my @args = (@_);

    # really, we shouldn't be doing this stuff from the command dispatcher

    $self->context(Prophet::CLIContext->new( app_handle => $self->app_handle));
    $self->context->setup_from_args(@args);

    my $args = $self->context->primary_commands;
    my $command = join ' ', @$args;

    my $dispatcher = $self->dispatcher_class->new(
        cli            => $self,
        context        => $self->context,
        dispatching_on => $args,
    );

    $dispatcher->run($command, %dispatcher_args);
}

=head2 invoke outhandle, ARGV_COMPATIBLE_ARRAY

Run the given command. If outhandle is true, select that as the file handle
for the duration of the command.

=cut

sub invoke {
    my ($self, $output, @args) = @_;
    my $ofh;

    $ofh = select $output if $output;
    my $ret = eval {
        local $SIG{__DIE__} = 'DEFAULT';
        $self->run_one_command(@args);
    };
    warn $@ if $@;
    select $ofh if $ofh;
    return $ret;
}


__PACKAGE__->meta->make_immutable;
no Moose;

1;

