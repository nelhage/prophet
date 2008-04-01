use warnings;
use strict;


package Prophet::Test::Arena;
use base qw/Class::Accessor/;
__PACKAGE__->mk_accessors(qw/chickens/);

use Acme::MetaSyntactic;
use Prophet::Test;


sub setup {
    my $self  = shift;
    my $count = shift;
    # create a set of n test participants
        # that should initialize their environments

    my @chickens;

    my $meta = Acme::MetaSyntactic->new();
    
    for my $name ($meta->name(pause_id => $count)) {
        push @chickens,Prophet::Test::Participant->new( { name => $name, arena => $self } );

    }
    $self->chickens(@chickens);
        
}

sub step {
    my $self = shift;
    my $step_name = shift || undef;
    for my $chicken (@{$self->chickens}) {
        as_user($chicken->name, sub {$chicken->take_one_step($step_name)});
    }

    # for x rounds, have each participant execute a random action
}

use List::MoreUtils qw/pairwise/;
use List::Util qw/shuffle/;
sub sync_all_pairs {
    my $self = shift;

    my @chickens_a = shuffle(@{$self->chickens});
    my @chickens_b = shuffle(@{$self->chickens});
    
    pairwise {
        warn $a;
        warn $b;
        return if $a->name eq $b->name;
        $a->sync_from_peer($b);
    } @chickens_a, @chickens_b;
    
    

}
1;