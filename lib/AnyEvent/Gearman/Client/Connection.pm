package AnyEvent::Gearman::Client::Connection;
use Any::Moose;

extends 'AnyEvent::Gearman::Connection';

no Any::Moose;

sub add_task {
    my ($self, $task, $on_complete, $on_error) = @_;

    $self->add_on_ready(
        sub {
            push @{ $self->_need_handle }, $task;
            $self->handler->push_write( $task->pack_req );
        },
        $on_error,
    );
}

sub process_packet {
    my $self = shift;

    my $handle = $self->handler;

    $handle->unshift_read( chunk => 4, sub { # \0RES
        unless ($_[1] eq "\0RES") {
            die qq[invalid packet: $_[1]"];
        }

        $handle->unshift_read( chunk => 8, sub {
            my ($type, $len)   = unpack('NN', $_[1]);
            my $packet_handler = $self->can("process_packet_$type");

            unless ($packet_handler) {
                # Ignore unimplement packet
                $handle->unshift_read( chunk => $len, sub {} ) if $len;
                return;
            }

            $packet_handler->( $self, $len );
        });
    });
}

sub process_work {              # common handler for WORK_*
    my ($self, $len, $cb) = @_;
    my $handle = $self->handler;

    $handle->unshift_read( line => "\0", sub {
        my $job_handle = $_[1];
        $len -= length($job_handle) + 1;

        $handle->unshift_read( chunk => $len, sub {
            $cb->( $job_handle, $_[1] );
        });
    });
}

sub process_packet_8 {          # JOB_CREATED
    my ($self, $len) = @_;

    my $handle = $self->handler;

    $handle->unshift_read( chunk => $len, sub {
        my $job_handle = $_[1];
        my $task = shift @{ $self->_need_handle } or return;

        $self->_job_handles->{ $job_handle } = $task;
        $task->event( 'on_created' );
    });
}

sub process_packet_12 {         # WORK_STATUS
    my ($self, $len) = @_;
    my $handle = $self->handler;

    $handle->unshift_read( line => "\0", sub {
        my $job_handle = $_[1];
        $len -= length($_[1]) + 1;

        $handle->unshift_read( line => "\0", sub {
            my $numerator = $_[1];
            $len -= length($_[1]) + 1;

            $handle->unshift_read( chunk => $len, sub {
                my $denominator = $_[1];

                my $task = $self->_job_handles->{ $job_handle } or return;
                $task->event( on_status => $numerator, $denominator );
            });
        });
     });
}

sub process_packet_13 {         # WORK_COMPLETE
    my ($self) = @_;

    push @_, sub {
        my ($job_handle, $data) = @_;

        my $task = delete $self->_job_handles->{ $job_handle } or return;
        $task->event( on_complete => $data );
    };

    goto \&process_work;
}

sub process_packet_14 {         # WORK_FAIL
    my ($self, $len) = @_;
    my $handle = $self->handler;

    $handle->unshift_read( chunk => $len, sub {
        my $job_handle = $_[1];
        my $task       = delete $self->_job_handles->{ $job_handle } or return;
        $task->event('on_fail');
    });
}

sub process_packet_25 {         # WORK_EXCEPTION
    my ($self) = @_;

    push @_, sub {
        my ($job_handle, $data) = @_;
        my $task = $self->_job_handles->{ $job_handle } or return;
        $task->event( on_exception => $data );
    };

    goto \&process_work;
}

sub process_packet_28 {         # WORK_DATA
    my ($self) = @_;

    push @_, sub {
        my ($job_handle, $data) = @_;

        my $task = $self->_job_handles->{ $job_handle } or return;
        $task->event( on_data => $data );
    };

    goto \&process_work;
}

sub process_packet_29 {         # WORK_WARNING
    my ($self) = @_;

    push @_, sub {
        my ($job_handle, $data) = @_;
        my $task = $self->_job_handles->{ $job_handle } or return;

        $task->event( on_warning => $data );
    };

    goto \&process_work;
}

__PACKAGE__->meta->make_immutable;

