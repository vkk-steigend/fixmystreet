package Open311::GetServiceRequests;

use Moo;
use Open311;
use FixMyStreet::DB;
use FixMyStreet::App::Model::PhotoSet;
use DateTime::Format::W3CDTF;

has system_user => ( is => 'rw' );
has start_date => ( is => 'ro', default => sub { undef } );
has end_date => ( is => 'ro', default => sub { undef } );
has suppress_alerts => ( is => 'rw', default => 0 );
has verbose => ( is => 'ro', default => 0 );
has schema => ( is =>'ro', lazy => 1, default => sub { FixMyStreet::DB->schema->connect } );

sub fetch {
    my $self = shift;

    my $bodies = $self->schema->resultset('Body')->search(
        {
            send_method     => 'Open311',
            fetch_problems  => 1,
            comment_user_id => { '!=', undef },
            endpoint        => { '!=', '' },
        }
    );

    while ( my $body = $bodies->next ) {

        my $o = Open311->new(
            endpoint     => $body->endpoint,
            api_key      => $body->api_key,
            jurisdiction => $body->jurisdiction,
        );

        $self->suppress_alerts( $body->suppress_alerts );
        $self->system_user( $body->comment_user );
        $self->create_problems( $o, $body );
    }
}

sub create_problems {
    my ( $self, $open311, $body ) = @_;

    my @args = ();

    if ( $self->start_date || $self->end_date ) {
        return 0 unless $self->start_date && $self->end_date;

        push @args, $self->start_date;
        push @args, $self->end_date;
    }

    my $requests = $open311->get_service_requests( );

    unless ( $open311->success ) {
        warn "Failed to fetch ServiceRequest Updates for " . $body->name . ":\n" . $open311->error
            if $self->verbose;
        return 0;
    }

    my $contacts = $self->schema->resultset('Contact')
        ->active
        ->search( { body_id => $body->id } );

    for my $request (@{$requests->{request}}) {
        # no point importing if we can't put it on the map
        unless ($request->{service_request_id} && $request->{lat} && $request->{long}) {
            warn "Not creating request '$request->{description}' for @{[$body->name]} as missing one of id, lat or long"
                if $self->verbose;
            next;
        }
        my $request_id = $request->{service_request_id};

        # TODO
        my %params;

        my ($latitude, $longitude) = ( $request->{lat}, $request->{long} );
        my $all_areas =
          mySociety::MaPit::call( 'point',
            "4326/$longitude,$latitude", %params );

        # skip if it doesn't look like it's for this body
        my @areas = grep { $all_areas->{$_->area_id} } $body->body_areas;
        unless (@areas) {
            warn "Not creating request id $request_id for @{[$body->name]} as outside body area"
                if $self->verbose;
            next;
        }

        my $updated_time = eval {
            DateTime::Format::W3CDTF->parse_datetime(
                $request->{updated_datetime} || ""
            )->set_time_zone(
                FixMyStreet->time_zone || FixMyStreet->local_time_zone
            );
        };
        if ($@) {
            warn "Not creating problem $request_id for @{[$body->name]}, bad update time"
                if $self->verbose;
            next;
        }

        my $updated = DateTime::Format::W3CDTF->format_datetime(
            $updated_time->clone->set_time_zone('UTC')
        );
        if (@args && ($updated lt $args[0] || $updated gt $args[1]) ) {
            warn "Problem id $request_id for @{[$body->name]} has an invalid time, not creating"
                if $self->verbose;
            next;
        }

        my $created_time = eval {
            DateTime::Format::W3CDTF->parse_datetime(
                $request->{requested_datetime} || ""
            )->set_time_zone(
                FixMyStreet->time_zone || FixMyStreet->local_time_zone
            );
        };
        $created_time = $updated_time if $@;

        my $problems;
        my $criteria = {
            external_id => $request_id,
        };
        $problems = $self->schema->resultset('Problem')->to_body($body)->search( $criteria );

        my @contacts = grep { $request->{service_code} eq $_->category } $contacts->all;
        my $contact = $contacts[0] ? $contacts[0]->category : 'Other';

        my $state = $self->map_state($request->{status});

        unless (my $p = $problems->first) {
            my $problem = $self->schema->resultset('Problem')->new(
                {
                    user => $self->system_user,
                    external_id => $request_id,
                    detail => $request->{description},
                    title => $request->{title} || $request->{service_name} . ' problem',
                    anonymous => 0,
                    name => $self->system_user->name,
                    confirmed => $created_time,
                    created => $created_time,
                    lastupdate => $updated_time,
                    whensent => $created_time,
                    state => $state,
                    postcode => '',
                    used_map => 1,
                    latitude => $request->{lat},
                    longitude => $request->{long},
                    areas => ',' . $body->id . ',',
                    bodies_str => $body->id,
                    send_method_used => 'Open311',
                    category => $contact,
                }
            );

            if ($request->{media_url}) {
                my $ua = LWP::UserAgent->new;
                my $res = $ua->get($request->{media_url});
                if ( $res->is_success && $res->content_type eq 'image/jpeg' ) {
                    my $photoset = FixMyStreet::App::Model::PhotoSet->new({
                        data_items => [ $res->decoded_content ],
                    });
                    $problem->photo($photoset->data);
                }
            }

            $problem->insert();
        }
    }

    return 1;
}

sub map_state {
    my $self           = shift;
    my $incoming_state = shift;

    $incoming_state = lc($incoming_state);
    $incoming_state =~ s/_/ /g;

    my %state_map = (
        fixed                         => 'fixed - council',
        'not councils responsibility' => 'not responsible',
        'no further action'           => 'unable to fix',
        open                          => 'confirmed',
    );

    return $state_map{$incoming_state} || $incoming_state;
}

1;
