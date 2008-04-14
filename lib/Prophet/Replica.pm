use warnings;
use strict;

package Prophet::Replica;
use base qw/Class::Accessor/;
use Params::Validate qw(:all);
use UNIVERSAL::require;


__PACKAGE__->mk_accessors(qw(state_handle ressource is_resdb db_uuid url));

use constant state_db_uuid => 'state';
use Module::Pluggable search_path => 'Prophet::Replica', sub_name => 'core_replica_types', require => 1, except => qr/Prophet::Replica::(.*)::/;

our $REPLICA_TYPE_MAP = {};
our $MERGETICKET_METATYPE = '_merge_tickets';

 __PACKAGE__->register_replica_scheme(scheme => $_->scheme, class => $_) for ( __PACKAGE__->core_replica_types);

=head1 NAME

Prophet::Replica

=head1 DESCRIPTION
                        
A base class for all Prophet replicas

=cut

=head1 METHODS

=head2 new

Instantiates a new replica

=cut

sub _unimplemented { my $self = shift; die ref($self). " does not implement ". shift; }

sub new {
    my $self = shift->SUPER::new(@_);
    $self->_rebless_to_replica_type(@_);
    $self->setup();
    return $self;
}

=head2 register_replica_scheme { class=> Some::Perl::Class, scheme => 'scheme:' }

B<Class Method>. Register a URI scheme C<scheme> to point to a replica object of type C<class>.

=cut

sub register_replica_scheme {
    my $class = shift;
    my %args = validate(@_, { class => 1, scheme => 1});

    $Prophet::Replica::REPLICA_TYPE_MAP->{$args{'scheme'}} = $args{'class'};



}
=head2 _rebless_to_replica_type

Reblesses this replica into the right sort of replica for whatever kind of replica $self->url points to


=cut
sub _rebless_to_replica_type {
    my $self = shift;


    my ($scheme, $real_url) = split(/:/,$self->url,2);
    $self->url($real_url);
    if ( my $class = $Prophet::Replica::REPLICA_TYPE_MAP->{$scheme}) {
    $class->require or die $@;
    return bless $self, $class;
    } else {
        die "$scheme isn't a replica type I know how to handle";
    }
}

sub import_changesets {
    my $self = shift;
    my %args = validate(
        @_,
        {   from               => { isa      => 'Prophet::Replica' },
            resdb              => { optional => 1 },
            resolver           => { optional => 1 },
            resolver_class     => { optional => 1 },
            conflict_callback  => { optional => 1 },
            reporting_callback => { optional => 1 }
        }
    );

    my $source = $args{'from'};

    $source->traverse_new_changesets(
        for      => $self,
        callback => sub {
            $self->integrate_changeset(
                changeset          => $_[0],
                conflict_callback  => $args{conflict_callback},
                reporting_callback => $args{'reporting_callback'},
                resolver           => $args{resolver},
                resolver_class     => $args{'resolver_class'},
                resdb              => $args{'resdb'},
            );
        }
    );
}

sub import_resolutions_from_remote_replica {
    my $self = shift;
    my %args = validate(
        @_,
        {   from              => { isa      => 'Prophet::Replica' },
            resolver          => { optional => 1 },
            resolver_class    => { optional => 1 },
            conflict_callback => { optional => 1 }
        }
    );
    my $source = $args{'from'};

    return unless $self->ressource;
    return unless $source->ressource;

    $self->ressource->import_changesets(
        from     => $source->ressource,
        resolver => sub { die "nono not yet" }

    );
}

=head2 integrate_changeset L<Prophet::ChangeSet>

If there are conflicts, generate a nullification change, figure out a conflict resolution and apply the nullification, original change and resolution all at once (as three separate changes).

If there are no conflicts, just apply the change.

=cut

sub integrate_changeset {
    my $self = shift;
    my %args = validate(
        @_,
        {   changeset          => { isa      => 'Prophet::ChangeSet' },
            resolver           => { optional => 1 },
            resolver_class     => { optional => 1 },
            resdb              => { optional => 1 },
            conflict_callback  => { optional => 1 },
            reporting_callback => { optional => 1 }
        }
    );

    my $changeset = $args{'changeset'};

    # when we start to integrate a changeset, we need to do a bit of housekeeping
    # We never want to merge in:
    # merge tickets that describe merges from the local node

    # When we integrate changes, sometimes we will get handed changes we already know about.
    #   - changes from local
    #   - changes from some other party we've merged from
    #   - merge tickets for the same
    # we'll want to skip or remove those changesets

    return if $changeset->original_source_uuid eq $self->uuid;

    $self->remove_redundant_data($changeset);    #Things we have already seen

    return if ( $changeset->is_empty or $changeset->is_nullification );

    if ( my $conflict = $self->conflicts_from_changeset($changeset) ) {
        $args{conflict_callback}->($conflict) if $args{'conflict_callback'};
        $conflict->resolvers( [ sub { $args{resolver}->(@_) } ] ) if $args{resolver};
        if ( $args{resolver_class} ) {
            $args{resolver_class}->require || die $@;
            $conflict->resolvers(
                [   sub {
                        $args{resolver_class}->new->run(@_);
                        }
                ]
                )

        }
        my $resolutions = $conflict->generate_resolution( $args{resdb} );

        #figure out our conflict resolution

     # IMPORTANT: these should be an atomic unit. dying here would be poor.  BUT WE WANT THEM AS THREEDIFFERENT SVN REVS
     # integrate the nullification change
        $self->record_changeset( $conflict->nullification_changeset );

        # integrate the original change
        $self->record_changeset_and_integration($changeset);

        # integrate the conflict resolution change
        $self->record_resolutions( $conflict->resolution_changeset );

        #            $self->ressource ? $self->ressource->prophet_handle : $self->prophet_handle );
        $args{'reporting_callback'}->( changeset => $changeset, conflict => $conflict )
            if ( $args{'reporting_callback'} );

    } else {
        $self->record_changeset_and_integration($changeset);
        $args{'reporting_callback'}->( changeset => $changeset ) if ( $args{'reporting_callback'} );

    }
}

=head2 integrate_changeset L<Prophet::ChangeSet>

Given a L<Prophet::ChangeSet>, integrates each and every change within that changeset into the handle's replica.

This routine also records that we've seen this changeset (and hence everything before it) from both the peer who sent it to us AND the replica who originally created it.

THIS OLD VERSION OF THE ROUTINE CAME FROM HANDLE

sub integrate_changeset {
    my $self      = shift;
    my ($changeset) = validate_pos(@_, { isa => 'Prophet::ChangeSet'});

    $self->begin_edit();
    $self->record_changeset($changeset);
    $self->record_changeset_integration($changeset);
    $self->commit_edit();
}

=cut



=head2 record_changeset_and_integration

=cut

sub record_changeset_and_integration {
    my $self      = shift;
    my $changeset = shift;

    Carp::cluck;
    $self->begin_edit;
    $self->record_changeset($changeset);

    my $state_handle = $self->state_handle;
    my $inside_edit = $state_handle->current_edit ? 1 : 0;
    $state_handle->begin_edit() unless ($inside_edit);
    $state_handle->record_changeset_integration($changeset);
    $state_handle->commit_edit() unless ($inside_edit);
    
    $self->commit_edit;

    return;
}
=head2 last_changeset_from_source $SOURCE_UUID

Returns the last changeset id seen from the source identified by $SOURCE_UUID

=cut

sub last_changeset_from_source {
    my $self = shift;
    my ($source) = validate_pos( @_, { type => SCALAR } );

    return $self->state_handle->_retrieve_metadata_for( $MERGETICKET_METATYPE, $source,
        'last-changeset' )
        || 0;

    # XXXX the code below is attempting to get the content over ra so we
    # can deal with remote svn repo. however this also assuming the
    # remote is having the same prophet_handle->db_rot
    # the code to handle remote svn should be
    # actually abstracted along when we design the sync prototype

    my ( $stream, $pool );

    my $filename = join( "/", $self->db_uuid, $MERGETICKET_METATYPE, $source );
    my ( $rev_fetched, $props )
        = eval { $self->ra->get_file( $filename, $self->most_recent_changeset, $stream, $pool ); };

    # XXX TODO this is hacky as hell and violates abstraction barriers in the name of doing things over the RA
    # because we want to be able to sync to a remote replica someday.

    return ( $props->{'last-changeset'} || 0 );

}


=head2 has_seen_changeset Prophet::ChangeSet

Returns true if we've previously integrated this changeset, even if we originally recieved it from a different peer

=cut

sub has_seen_changeset {
    my $self = shift;
    my ($changeset) = validate_pos( @_, { isa => "Prophet::ChangeSet" } );

    # If the changeset originated locally, we never want it
    return 1 if $changeset->original_source_uuid eq $self->uuid;

    # Otherwise, if the we have a merge ticket from the source, we don't want the changeset
    my $last = $self->last_changeset_from_source( $changeset->original_source_uuid );

    # if the source's sequence # is >= the changeset's sequence #, we can safely skip it
    return 1 if ( $last >= $changeset->original_sequence_no );
    return undef;
}

=head2 changeset_will_conflict Prophet::ChangeSet

Returns true if any change that's part of this changeset won't apply cleanly to the head of the current replica

=cut

sub changeset_will_conflict {
    my $self = shift;
    my ($changeset) = validate_pos( @_, { isa => "Prophet::ChangeSet" } );

    return 1 if ( $self->conflicts_from_changeset($changeset) );

    return undef;

}

=head2 conflicts_from_changeset Prophet::ChangeSet

Returns a L<Prophet::Conflict/> object if the supplied L<Prophet::ChangeSet/>
will generate conflicts if applied to the current replica.

Returns undef if the current changeset wouldn't generate a conflict.

=cut

sub conflicts_from_changeset {
    my $self = shift;
    my ($changeset) = validate_pos( @_, { isa => "Prophet::ChangeSet" } );

    my $conflict = Prophet::Conflict->new( { changeset => $changeset, prophet_handle => $self} );

    $conflict->analyze_changeset();

    return undef unless @{ $conflict->conflicting_changes };

    return $conflict;

}

sub remove_redundant_data {
    my ( $self, $changeset ) = @_;

    # XXX: encapsulation
    $changeset->{changes} = [
        grep { $self->is_resdb || $_->record_type ne '_prophet_resolution' }
            grep { !( $_->record_type eq $MERGETICKET_METATYPE && $_->node_uuid eq $self->uuid ) }
            $changeset->changes
    ];
}

=head2 traverse_new_changesets ( for => $replica, callback => sub { my $changeset = shift; ... } )

Traverse the new changesets for C<$replica> and call C<callback> for each new changesets.

XXX: this also provide hinting callbacks for the caller to know in
advance how many changesets are there for traversal.

=cut

sub traverse_new_changesets {
    my $self = shift;
    my %args = validate(
        @_,
        {   for      => { isa => 'Prophet::Replica' },
            callback => 1,
        }
    );

    if ( $self->db_uuid && $args{for}->db_uuid && $self->db_uuid ne $args{for}->db_uuid ) {

        #warn "HEY. You should not be merging between two replicas with different database uuids";
        # XXX TODO
    }

    $self->traverse_changesets(
        after    => $args{for}->last_changeset_from_source( $self->uuid ),
        callback => sub {
            $args{callback}->( $_[0] )
                if $self->should_send_changeset( changeset => $_[0], to => $args{for} );
        }
    );
}

=head2 news_changesets_for Prophet::Replica

DEPRECATED: use traverse_new_changesets instead

Returns the local changesets that have not yet been seen by the replica we're passing in.

=cut


sub new_changesets_for {
    my $self = shift;
    my ($other) = validate_pos( @_, { isa => 'Prophet::Replica' } );

    my @result;
    $self->traverse_new_changesets( for => $other, callback => sub { push @result, $_[0] } );

    return \@result;
}

=head2 should_send_changeset { to => Prophet::Replica, changeset => Prophet::ChangeSet }

Returns true if the replica C<to> hasn't yet seen the changeset C<changeset>


=cut

sub should_send_changeset {
    my $self = shift;
    my %args = validate( @_, { to => { isa => 'Prophet::Replica' }, changeset => { isa => 'Prophet::ChangeSet' } } );

    return undef if ( $args{'changeset'}->is_nullification || $args{'changeset'}->is_resolution );
    return undef if $args{'to'}->has_seen_changeset( $args{'changeset'} );

    return 1;
}

=head2 fetch_changesets { after => SEQUENCE_NO } 

Fetch all changesets from the source. 
        
Returns a reference to an array of L<Prophet::ChangeSet/> objects.

See also L<traverse_new_changesets> for replica implementations to provide streamly interface
        

=cut    

sub fetch_changesets {
    my $self = shift;
    my %args = validate( @_, { after => 1 } );
    my @results;

    $self->traverse_changesets( %args, callback => sub { push @results, $_[0] } );

    return \@results;
}

sub traverse_changesets {
    my $self = shift;
    my %args = validate(
        @_,
        {   after    => 1,
            callback => 1,
        }
    );

    my $first_rev = ( $args{'after'} + 1 ) || 1;
    my $last_rev = $self->most_recent_changeset();


    die "you must implement most_recent_changeset in " . ref($self) . ", or override traverse_changesets"
        unless defined $last_rev;

    for my $rev ( $first_rev .. $self->most_recent_changeset ) {
        $args{callback}->( $self->fetch_changeset($rev) );
    }
}

=head2 export_to { path => $PATH } 

This routine will export a copy of this prophet database replica to a flat file on disk suitable for 
publishing via HTTP or over a local filesystem for other Prophet replicas to clone or incorporate changes from.

See C<Prophet::ReplicaExporter>

=cut

sub export_to {
    my $self = shift;
    my %args = validate( @_, { path => 1, } );
    Prophet::ReplicaExporter->require();

    my $exporter = Prophet::ReplicaExporter->new({target_path => $args{'path'}, replica => $self});
    $exporter->export();
}


=head1 methods to be implemented by a replica backend



=cut


=head2 uuid 

Returns this replica's uuid

=cut

sub uuid {}

=head2 most_recent_changeset

Returns the sequence # of the most recently committed changeset

=cut

sub most_recent_changeset {return undef }

=head2 fetch_changeset SEQUENCE_NO

Returns a Prophet::ChangeSet object for changeset # C<SEQUENCE_NO>

=cut

sub fetch_changeset {} 








=head2  can_write_changesets

Returns true if this source is one we know how to write to (and have permission to write to)

Returns false otherwise

=cut






sub can_read_records { undef }
sub can_write_records { undef }
sub can_read_changesets { undef }
sub can_write_changesets { undef } 



=head1 CODE BELOW THIS LINE USED TO BE IN HANDLE




=head2 record_resolutions Prophet::ChangeSet

Given a resolution changeset

record all the resolution changesets as well as resolution records in the local resolution database;

Called ONLY on local resolution creation. (Synced resolutions are just synced as records)

=cut

sub record_resolutions {
    my $self       = shift;
    my ($changeset) = validate_pos(@_, { isa => 'Prophet::ChangeSet'});

        
        $self->_unimplemented("record_resolutions (since there is no writable handle)") unless ($self->can_write_changesets);

       my $res_handle =  $self->ressource ? $self->ressource: $self;


    return unless $changeset->changes;

    $self->begin_edit();
    $self->record_changeset($changeset);
    $res_handle->record_resolution($_) for $changeset->changes;
    $self->commit_edit();
}

=head2 record_resolution Prophet::Change
 
Called ONLY on local resolution creation. (Synced resolutions are just synced as records)

=cut

sub record_resolution {
    my $self      = shift;
    my ($change) = validate_pos(@_, { isa => 'Prophet::Change'});

    return 1 if $self->record_exists(
        uuid => $self->uuid,
        type => '_prophet_resolution-' . $change->resolution_cas
    );

    $self->create_node(
        uuid  => $self->uuid,
        type  => '_prophet_resolution-' . $change->resolution_cas,
        props => {
            _meta => $change->change_type,
            map { $_->name => $_->new_value } $change->prop_changes
        }
    );
}





=head1 Routines dealing with integrating changesets into a replica

=head2 record_changeset Prophet::ChangeSet

Inside an edit (transaction), integrate all changes in this transaction
and then call the _post_process_integrated_changeset() hook

=cut

sub record_changeset {
    my $self      = shift;
    my ($changeset) = validate_pos(@_, { isa => 'Prophet::ChangeSet'});
    $self->_unimplemented ('record_changeset') unless ($self->can_write_changesets);
    eval {
        my $inside_edit = $self->current_edit ? 1 : 0;
        $self->begin_edit() unless ($inside_edit);
        $self->_integrate_change($_) for ( $changeset->changes );
        $self->_post_process_integrated_changeset($changeset);
        $self->commit_edit() unless ($inside_edit);
    };
    die($@) if ($@);
}

sub _integrate_change {
    my $self   = shift;
    my ($change) = validate_pos(@_, { isa => 'Prophet::Change'});

    my %new_props = map { $_->name => $_->new_value } $change->prop_changes;
    if ( $change->change_type eq 'add_file' ) {
        $self->create_node( type  => $change->record_type, uuid  => $change->node_uuid, props => \%new_props);
    } elsif ( $change->change_type eq 'add_dir' ) {
    } elsif ( $change->change_type eq 'update_file' ) {
        $self->set_node_props( type  => $change->record_type, uuid  => $change->node_uuid, props => \%new_props);
    } elsif ( $change->change_type eq 'delete' ) {
        $self->delete_node( type => $change->record_type, uuid => $change->node_uuid);
    } else {
        Carp::confess( " I have never heard of the change type: " . $change->change_type );
    }

}







=head2 record_changeset_integration L<Prophet::ChangeSet>

This routine records the immediately upstream and original source
uuid and sequence numbers for this changeset. Prophet uses this
data to make sane choices about later replay and merge operations


=cut

sub record_changeset_integration {
    my $self = shift;
    my ($changeset) = validate_pos( @_, { isa => 'Prophet::ChangeSet' } );

    # Record a merge ticket for the changeset's "original" source
    $self->_record_merge_ticket( $changeset->original_source_uuid, $changeset->original_sequence_no );

}
sub _record_merge_ticket {
    my $self = shift;
    my ( $source_uuid, $sequence_no ) = validate_pos( @_, 1, 1 );
    return $self->_record_metadata_for( $MERGETICKET_METATYPE, $source_uuid, 'last-changeset', $sequence_no );
}






=head1 metadata storage routines 

=cut 
=head2 metadata_storage $RECORD_TYPE, $PROPERTY_NAME

Returns a function which takes a UUID and an optional value to get (or set) metadata rows in a metadata table.
We use this to record things like merge tickets


=cut
sub metadata_storage {
    my $self = shift;
    my ( $type, $prop_name ) = validate_pos( @_, 1, 1 );
    return sub {
        my $uuid = shift;
        if (@_) {
            return $self->_record_metadata_for( $type, $uuid, $prop_name, @_ );
        }
        return $self->_retrieve_metadata_for( $type, $uuid, $prop_name );

    };
}
sub _retrieve_metadata_for {
    my $self = shift;
    my ( $name, $source_uuid, $prop_name ) = validate_pos( @_, 1, 1, 1 );

    my $entry = Prophet::Record->new( handle => $self, type => $name );
    $entry->load( uuid => $source_uuid );
    return eval { $entry->prop($prop_name) };

}
sub _record_metadata_for {
    my $self = shift;
    my ( $name, $source_uuid, $prop_name, $content ) = validate_pos( @_, 1, 1, 1, 1 );

    my $props = eval { $self->get_node_props( uuid => $source_uuid, type => $name ) };

    # XXX: do set-prop when exists, and just create new node with all props is probably better
    unless ( $props->{$prop_name} ) {
        eval { $self->create_node( uuid => $source_uuid, type => $name, props => {} ) };
    }

    $self->set_node_props(
        uuid  => $source_uuid,
        type  => $name,
        props => { $prop_name => $content }
    );
}


=head1 The following functions need to be implemented by any Prophet backing store.

=head2 uuid

Returns this replica's UUID

=head2 create_node { type => $TYPE, uuid => $uuid, props => { key-value pairs }}

Create a new record of type C<$type> with uuid C<$uuid>  within the current replica.

Sets the record's properties to the key-value hash passed in as the C<props> argument.

If called from within an edit, it uses the current edit. Otherwise it manufactures and finalizes one of its own.



=head2 delete_node {uuid => $uuid, type => $type }

Deletes the node C<$uuid> of type C<$type> from the current replica. 

Manufactures its own new edit if C<$self->current_edit> is undefined.

=head2 set_node_props { uuid => $uuid, type => $type, props => {hash of kv pairs }}


Updates the record of type C<$type> with uuid C<$uuid> to set each property defined by the props hash. It does NOT alter any property not defined by the props hash.

Manufactures its own current edit if none exists.


=head2 get_node_props {uuid => $uuid, type => $type, root => $root }

Returns a hashref of all properties for the record of type $type with uuid C<$uuid>.

'root' is an optional argument which you can use to pass in an alternate historical version of the replica to inspect.  Code to look at the immediately previous version of a record might look like:

    $handle->get_node_props(
        type => $record->type,
        uuid => $record->uuid,
        root => $self->repo_handle->fs->revision_root( $self->repo_handle->fs->youngest_rev - 1 )
    );

=head2 record_exists {uuid => $uuid, type => $type, root => $root }

Returns true if the node in question exists. False otherwise


=head2 list_nodes { type => $type }

Returns a reference to a list of all the records of type $type

=head2 list_nodes

Returns a reference to a list of all the known types in your Prophet database


=head2 type_exists { type => $type }

Returns true if we have any nodes of type C<$type>



=cut

=head2 The following functions need to be implemented by any _writable_ prophet backing store

=cut



=head2 The following optional routines are provided for you to override with backing-store specific behaviour


=head3 _post_process_integrated_changeset Prophet::ChangeSet

Called after the replica has integrated a new changeset but before closing the current transaction/edit.

The SVN backend, for example, uses this to record author metadata about this changeset.

=cut
sub _post_process_integrated_changeset {
    return 1;
}




1;

