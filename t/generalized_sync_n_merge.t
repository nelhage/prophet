use warnings;
use strict;

use Prophet::Test 'no_plan';
use Test::Exception;

use_ok('Prophet::Test::Arena');
use_ok('Prophet::Test::Participant');

my $arena = Prophet::Test::Arena->new();
$arena->setup(5);


for(1..10) {
    $arena->step();
}

exit;


# helper routines

sub as_user {}








1;