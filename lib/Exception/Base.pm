#!/usr/bin/perl -c

package Exception::Base;
use 5.006;
our $VERSION = '0.20';

=head1 NAME

Exception::Base - Lightweight exceptions

=head1 SYNOPSIS

  # Use module and create needed exceptions
  use Exception::Base
     'Exception::Runtime',              # create new module
     'Exception::System',               # load existing module
     'Exception::IO',          => {
         isa => 'Exception::System' },  # create new based on existing
     'Exception::FileNotFound' => {
         isa => 'Exception::IO',        # create new based on previous
         message => 'File not found',   # override default message
         has => [ 'filename' ],         # define new rw attribute
         string_attributes => [ 'message', 'filename' ],
     };                                 # output message and filename

  # eval is used as "try" block
  eval {
    open my $file, '/etc/passwd'
      or Exception::FileNotFound->throw(
            message=>'Something wrong',
            filename=>'/etc/passwd');
  };
  # standard syntax for older Perl
  if ($@) {
    my $e = Exception::Base->catch;   # convert $@ into exception
    if ($e->isa('Exception::IO')) { warn "IO problem"; }
    elsif ($e->isa('Exception::Eval')) { warn "eval died"; }
    elsif ($e->isa('Exception::Runtime')) { warn "some runtime was caught"; }
    elsif ($e->matches({value=>9})) { warn "something happened"; }
    elsif ($e->matches(qr/^Error/)) { warn "some error based on regex"; }
    else { $e->throw; } # rethrow the exception
  }
  # alternative syntax for Perl 5.10
  use feature 'switch';
  if ($@) {
    given (my $e = Exception::Base->catch) {
      when (['Exception::IO']) { warn "IO problem"; }
      when (['Exception::Eval']) { warn "eval died"; }
      when (['Exception::Runtime']) { warn "some runtime was caught"; }
      when ({value=>9}) { warn "something happened"; }
      when (qr/^Error/) { warn "some error based on regex"; }
      default { $e->throw; } # rethrow the exception
    }
  }

  # $@ has to be recovered ASAP!
  eval { die "this die will be caught" };
  my $e = Exception::Base->catch;
  eval { die "this die will be ignored" };
  if ($e) {
     (...)
  }

  # the exception can be thrown later
  my $e = Exception::Base->new;
  # (...)
  $e->throw;

  # ignore our package in stack trace
  package My::Package;
  use Exception::Base '+ignore_package' => __PACKAGE__;

  # define new exception in separate module
  package Exception::My;
  use Exception::Base (__PACKAGE__) => {
      has => ['myattr'],
  };

  # run Perl with changed verbosity for debugging purposes
  $ perl -MException::Base=verbosity,4 script.pl

=head1 DESCRIPTION

This class implements a fully OO exception mechanism similar to
L<Exception::Class> or L<Class::Throwable>.  It provides a simple interface
allowing programmers to declare exception classes.  These classes can be
thrown and caught.  Each uncaught exception prints full stack trace if the
default verbosity is uppered for debugging purposes.

The features of B<Exception::Base>:

=over 2

=item *

fast implementation of the exception class

=item *

fully OO without closures and source code filtering

=item *

does not mess with $SIG{__DIE__} and $SIG{__WARN__}

=item *

no external modules dependencies, requires core Perl modules only

=item *

the default behaviour of exception class can be changed globally or just for
the thrown exception

=item *

matching the exception by class, message or other attributes

=item *

matching with string, regex or closure function

=item *

creating automatically the derived exception classes ("use" interface)

=item *

easly expendable, see L<Exception::System> class for example

=item *

prints just an error message or dumps full stack trace

=item *

can propagate (rethrow) an exception

=item *

can ignore some packages for stack trace output

=item *

some defaults (i.e. verbosity) can be different for different exceptions

=back

=for readme stop

=cut


use strict;
use warnings;

use utf8;


# Safe operations on symbol stash
BEGIN {
    eval {
        require Symbol;
        Symbol::qualify_to_ref('qualify_to_ref');
    };
    if (not $@) {
        *_qualify_to_ref = \*Symbol::qualify_to_ref;
    }
    else {
        *_qualify_to_ref = sub ($;) { no strict 'refs'; \*{ $_[0] } };
    };
};


# Use weaken ref on stack if available
BEGIN {
    eval {
        require Scalar::Util;
        my $ref = \1;
        Scalar::Util::weaken($ref);
    };
    if (not $@) {
        *_HAVE_SCALAR_UTIL_WEAKEN = sub () { !! 1 };
    }
    else {
        *_HAVE_SCALAR_UTIL_WEAKEN = sub () { ! 1 };
    };
};


# Overload the cast operations
use overload 'bool'   => 'to_bool',
             '0+'     => 'to_number',
             '""'     => 'to_string',
             fallback => 1;

# Overload smart matching for Perl 5.10.  Don't "use if" not available for base Perl 5.6.
BEGIN {
    eval q{
        use overload
             '~~'     => 'matches',
             fallback => 1;
    } if ($] >= 5.010);
};


# Constant regexp for numerify value check
use constant _RE_NUM_INT  => qr/^[+-]?\d+$/;


# List of class attributes (name => { is=>ro|rw, default=>value })
use constant ATTRS => {
    defaults             => { },
    default_attribute    => { default => 'message' },
    numeric_attribute    => { default => 'value' },
    eval_attribute       => { default => 'message' },
    string_attributes    => { default => [ 'message' ] },
    message              => { is => 'rw', default => 'Unknown exception' },
    value                => { is => 'rw', default => 0 },
    caller_stack         => { is => 'ro' },
    propagated_stack     => { is => 'ro' },
    egid                 => { is => 'ro' },
    euid                 => { is => 'ro' },
    gid                  => { is => 'ro' },
    pid                  => { is => 'ro' },
    tid                  => { is => 'ro' },
    time                 => { is => 'ro' },
    uid                  => { is => 'ro' },
    verbosity            => { is => 'rw', default => 2 },
    ignore_package       => { is => 'rw', default => [ ] },
    ignore_class         => { is => 'rw', default => [ ] },
    ignore_level         => { is => 'rw', default => 0 },
    max_arg_len          => { is => 'rw', default => 64 },
    max_arg_nums         => { is => 'rw', default => 8 },
    max_eval_len         => { is => 'rw', default => 0 },
};


# Cache for class' ATTRS
my %Class_Attributes;


# Cache for class' defaults
my %Class_Defaults;


# Cache for $obj->isa(__PACKAGE__)
my %Isa_Package;


# Create additional exception packages
sub import {
    my $pkg = shift;

    while (defined $_[0]) {
        my $name = shift @_;
        if ($name =~ /^([+-]?)([a-z0-9_]+)$/) {
            # Lower case: change default
            my ($modifier, $key) = ($1, $2);
            my $value = shift;
            $pkg->_modify_default($key, $value, $modifier);
        }
        else {
            # Try to use external module
            my $param = shift @_ if defined $_[0] and ref $_[0] eq 'HASH';

            my $version = defined $param->{version} ? $param->{version} : 0;
            my $mod_version = do { local $SIG{__DIE__}; eval { $name->VERSION } } || 0;

            if (caller ne $name) {
                next if $mod_version and $mod_version >= $version;

                # Package is needed
                do { local $SIG{__DIE__}; eval { $pkg->_load_package($name, $version); } };
                if ($@) {
                    # Die unless can't load module
                    if ($@ !~ /Can\'t locate/) {
                        Exception::Base->throw(
                            message => "Can not load available $name class: $@",
                            verbosity => 1
                        );
                    }
                }
                else {
                    # Module is loaded: go to next
                    next;
                }
            }

            next if $name eq __PACKAGE__;

            # Package not found so it have to be created
            if ($pkg ne __PACKAGE__) {
                Exception::Base->throw(
                    message => "Exceptions can only be created with " . __PACKAGE__ . " class",
                    verbosity => 1
                );
            }
            my $isa = defined $param->{isa} ? $param->{isa} : __PACKAGE__;
            $version = 0.01 if not $version;
            my $has = defined $param->{has} ? $param->{has} : [ ];
            $has = [ $has ] if ref $has ne 'ARRAY';

            # Base class is needed
            {
                if (not defined do { local $SIG{__DIE__}; eval { $isa->VERSION } }) {
                    eval { $pkg->_load_package($isa) };
                    if ($@) {
                        Exception::Base->throw(
                            message => "Base class $isa for class $name can not be found",
                            verbosity => 1
                        );
                    }
                }
            }

            # Handle defaults for object attributes
            my $attributes;
            do { local $SIG{__DIE__}; eval { $attributes = $isa->ATTRS } };
            if ($@) {
                Exception::Base->throw(
                    message => "$name class is based on $isa class which does not implement ATTRS",
                    verbosity => 1
                );
            }

            # Create the hash with overriden attributes
            my %overriden_attributes;
            # Class => { has => [ "attr1", "attr2", "attr3", ... ] }
            foreach my $attribute (@{ $has }) {
                if ($attribute =~ /^(isa|version|has)$/ or $isa->can($attribute)) {
                    Exception::Base->throw(
                        message => "Attribute name `$attribute' can not be defined for $name class"
                    );
                }
                $overriden_attributes{$attribute} = { is => 'rw' };
            }
            # Class => { message => "overriden default", ... }
            foreach my $attribute (keys %{ $param }) {
                next if $attribute =~ /^(isa|version|has)$/;
                if (not exists $attributes->{$attribute}->{default}
                    and not exists $overriden_attributes{$attribute})
                {
                    Exception::Base->throw(
                        message => "$isa class does not implement default value for `$attribute' attribute",
                        verbosity => 1
                    );
                }
                $overriden_attributes{$attribute} = {};
                $overriden_attributes{$attribute}->{default} = $param->{$attribute};
                foreach my $property (keys %{ $attributes->{$attribute} }) {
                    next if $property eq 'default';
                    $overriden_attributes{$attribute}->{$property} = $attributes->{$attribute}->{$property};
                }
            }

            # Create the new package
            ${ *{_qualify_to_ref($name . '::VERSION')} } = $version;
            @{ *{_qualify_to_ref($name . '::ISA')} } = ($isa);
            *{_qualify_to_ref($name . '::ATTRS')} = sub () {
                +{ %{ $isa->ATTRS }, %overriden_attributes };
            };
            $name->_make_accessors;
        }
    }

    return 1;
}


# Constructor
sub new {
    my $class = shift;
    $class = ref $class if ref $class;

    my $attributes;
    my $defaults;

    # Use cached value if available
    if (not defined $Class_Attributes{$class}) {
        $attributes = $Class_Attributes{$class} = $class->ATTRS;
        $defaults = $Class_Defaults{$class} = {
            map { $_ => $attributes->{$_}->{default} }
                grep { defined $attributes->{$_}->{default} }
                    (keys %$attributes)
        };
    }
    else {
        $attributes = $Class_Attributes{$class};
        $defaults = $Class_Defaults{$class};
    }

    my $self = {};

    # If the attribute is rw, initialize its value. Otherwise: ignore.
    no warnings 'uninitialized';
    my %args = @_;
    foreach my $key (keys %args) {
        if ($attributes->{$key}->{is} eq 'rw') {
            $self->{$key} = $args{$key};
        }
    }

    # Defaults for this object
    $self->{defaults} = { %$defaults };

    bless $self => $class;

    # Collect system data and eval error
    $self->_collect_system_data;

    return $self;
}


# Create the exception and throw it or rethrow existing
sub throw {
    my $self = shift;

    my $class = ref $self ? ref $self : $self;
    my $old;

    if (not ref $self) {
        # CLASS->throw
        if (not ref $_[0]) {
            # Throw new exception
            if (scalar @_ % 2 == 0) {
                # Throw normal error
                die $self->new(@_);
            }
            else {
                # First argument is a default attribute; it can be overriden with normal args
                my $argument = shift;
                my $e = $self->new(@_);
                my $default_attribute = $e->{defaults}->{default_attribute};
                $e->{$default_attribute} = $argument if not defined $e->{$default_attribute};
                die $e;
            }
        }
        else {
            # First argument is an old exception
            $old = shift;
        }
    }
    else {
        # $e->throw
        $old = $self;
    }

    # Rethrow old exception with replaced attributes
    no warnings 'uninitialized';
    my %args = @_;
    my $attrs = $old->ATTRS;
    foreach my $key (keys %args) {
        if ($attrs->{$key}->{is} eq 'rw') {
            $old->{$key} = $args{$key};
        }
    }
    $old->PROPAGATE;
    if (ref $old ne $class) {
        # Rebless old object for new class
        bless $old => $class;
    }

    die $old;
}


# Recover $@ variable and return exception object
sub catch {
    my $self = shift;

    # Recover class from object or set the default
    my $class = ref $self || $self || __PACKAGE__;

    my $e;
    my $new_e;

    # Recover exception from $@ and clear it
    $e = $@;
    $@ = '';

    if (ref $e and do { local $@; local $SIG{__DIE__}; eval { $e->isa(__PACKAGE__) } }) {
        # Caught exception
        $new_e = $e;
    }
    elsif ($e eq '') {
        # No error in $@
        $new_e = undef;
    }
    else {
        # New exception based on error from $@. Clean up the message.
        while ($e =~ s/\t\.\.\.propagated at (?!.*\bat\b.*).* line \d+( thread \d+)?\.\n$//s) { }
        $e =~ s/( at (?!.*\bat\b.*).* line \d+( thread \d+)?\.)?\n$//s;
        $new_e = $class->new;
        my $eval_attribute = $new_e->{defaults}->{eval_attribute};
        $new_e->{$eval_attribute} = $e;
    };

    return $new_e;
};


# Smart matching.
sub matches {
    my ($self, $that) = @_;
    my @args;

    my $default_attribute = $self->{defaults}->{default_attribute};
    my $numeric_attribute = $self->{defaults}->{numeric_attribute};

    if (ref $that eq 'ARRAY') {
        @args = ( '-isa' => $that );
    }
    elsif (ref $that eq 'HASH') {
        @args = %$that;
    }
    elsif (ref $that eq 'Regexp' or ref $that eq 'CODE' or not defined $that) {
        @args = ( $that );
    }
    elsif (ref $that) {
        return '';
    }
    elsif ($that =~ _RE_NUM_INT) {
        @args = ( $numeric_attribute => $that );
    }
    else {
        @args = ( $that );
    }

    return '' unless @args;

    # Odd number of arguments - first is default attribute
    if (scalar @args % 2 == 1) {
        my $val = shift @args;
        if (ref $val eq 'ARRAY') {
            my $arrret = 0;
            foreach my $arrval (@{ $val }) {
                if (not defined $arrval) {
                    $arrret = 1 if not grep { defined $_ and $_ ne '' } map { $self->{$_} } @{ $self->{defaults}->{string_attributes} };
                }
                elsif (not ref $arrval and $arrval =~ _RE_NUM_INT) {
                    no warnings 'numeric', 'uninitialized';
                    $arrret = 1 if $self->{$numeric_attribute} == $arrval;
                }
                elsif (not grep { defined $_ and $_ ne '' } map { $self->{$_} } @{ $self->{defaults}->{string_attributes} }) {
                    next;
                }
                elsif (ref $arrval eq 'CODE') {
                    local $_ = join ': ', grep { defined $_ and $_ ne '' } map { $self->{$_} } @{ $self->{defaults}->{string_attributes} };
                    $arrret = 1 if &$arrval;
                }
                elsif (ref $arrval eq 'Regexp') {
                    local $_ = join ': ', grep { defined $_ and $_ ne '' } map { $self->{$_} } @{ $self->{defaults}->{string_attributes} };
                    $arrret = 1 if /$arrval/;
                }
                else {
                    local $_ = join ': ', grep { defined $_ and $_ ne '' } map { $self->{$_} } @{ $self->{defaults}->{string_attributes} };
                    $arrret = 1 if $_ eq $arrval;
                }
                last if $arrret;
            }
            # Fail unless at least one condition is true
            return '' if not $arrret;
        }
        elsif (not defined $val) {
            return '' if grep { defined $_ and $_ ne '' } map { $self->{$_} } @{ $self->{defaults}->{string_attributes} };
        }
        elsif (not ref $val and $val =~ _RE_NUM_INT) {
            no warnings 'numeric', 'uninitialized';
            return '' if $self->{$numeric_attribute} != $val;
        }
        elsif (not grep { defined $_ and $_ ne '' } map { $self->{$_} } @{ $self->{defaults}->{string_attributes} }) {
            return '';
        }
        elsif (ref $val eq 'CODE') {
            local $_ = join ': ', grep { defined $_ and $_ ne '' } map { $self->{$_} } @{ $self->{defaults}->{string_attributes} };
            return '' if not &$val;
        }
        elsif (ref $val eq 'Regexp') {
            local $_ = join ': ', grep { defined $_ and $_ ne '' } map { $self->{$_} } @{ $self->{defaults}->{string_attributes} };
            return '' if not /$val/;
        }
        else {
            local $_ = join ': ', grep { defined $_ and $_ ne '' } map { $self->{$_} } @{ $self->{defaults}->{string_attributes} };
            return '' if $_ ne $val;
        }
        return 1 unless @args;
    }


    my %args = @args;
    while (my($key,$val) = each %args) {
        if ($key eq '-default') {
            $key = $default_attribute;
        }

        if ($key eq '-isa') {
            if (ref $val eq 'ARRAY') {
                my $arrret = 0;
                foreach my $arrval (@{ $val }) {
                    next if not defined $arrval;
                    $arrret = 1 if $self->isa($arrval);
                    last if $arrret;
                }
                return '' if not $arrret;
            }
            else {
                return '' if not $self->isa($val);
            }
        }
        elsif ($key eq '-has') {
            if (ref $val eq 'ARRAY') {
                my $arrret = 0;
                foreach my $arrval (@{ $val }) {
                    next if not defined $arrval;
                    $arrret = 1 if exists $self->ATTRS->{$arrval};
                    last if $arrret;
                }
                return '' if not $arrret;
            }
            else {
                return '' if not $self->ATTRS->{$val};
            }
        }
        elsif (ref $val eq 'ARRAY') {
            my $arrret = 0;
            foreach my $arrval (@{ $val }) {
                if (not defined $arrval) {
                    $arrret = 1 if not defined $self->{$key};
                }
                elsif (not defined $self->{$key}) {
                    next;
                }
                elsif (ref $arrval eq 'CODE') {
                    local $_ = $self->{$key};
                    $arrret = 1 if &$arrval;
                }
                elsif (ref $arrval eq 'Regexp') {
                    local $_ = $self->{$key};
                    $arrret = 1 if /$arrval/;
                }
                else {
                    $arrret = 1 if $self->{$key} eq $arrval;
                }
                last if $arrret;
            }
            return '' if not $arrret;
        }
        elsif (not defined $val) {
            return '' if exists $self->{$key} && defined $self->{$key};
        }
        elsif (not ref $val and $val =~ _RE_NUM_INT) {
            no warnings 'numeric', 'uninitialized';
            return '' if $self->{$key} != $val;
        }
        elsif (not defined $self->{$key}) {
            return '';
        }
        elsif (ref $val eq 'CODE') {
            local $_ = $self->{$key};
            return '' if not &$val;
        }
        elsif (ref $val eq 'Regexp') {
            local $_ = $self->{$key};
            return '' if not /$val/;
        }
        else {
            return '' if $self->{$key} ne $val;
        }
    }

    return 1;
}


# Convert an exception to string
sub to_string {
    my ($self) = @_;

    my $verbosity = defined $self->{verbosity}
                    ? $self->{verbosity}
                    : $self->{defaults}->{verbosity};

    my $message = join ': ', grep { defined $_ and $_ ne '' } map { $self->{$_} } @{ $self->{defaults}->{string_attributes} };

    if ($message eq '') {
        foreach (reverse @{ $self->{defaults}->{string_attributes} }) {
            $message = $self->{defaults}->{$_};
            last if defined $message;
        };
    };

    my $string;
    if ($verbosity == 1) {
        return $message if $message =~ /\n$/;

        return $message . "\n";
    }
    elsif ($verbosity == 2) {
        return $message if $message =~ /\n$/;

        my @stacktrace = $self->get_caller_stacktrace;
        return $message . $stacktrace[0] . ".\n";
    }
    elsif ($verbosity >= 3) {
        return ref($self) . ": " . $message . $self->get_caller_stacktrace;
    };

    return "";
};


# Convert an exception to number
sub to_number {
    my ($self) = @_;
    my $numeric_attribute = $self->{defaults}->{numeric_attribute};

    no warnings 'numeric';
    return 0+ $self->{$numeric_attribute} if defined $self->{$numeric_attribute};
    return 0+ $self->{defaults}->{$numeric_attribute} if defined $self->{defaults}->{$numeric_attribute};
    return 0;
};


# Convert an exception to bool (always true)
sub to_bool {
    return !! 1;
};


# Stringify caller backtrace. Stolen from Carp
sub get_caller_stacktrace {
    my ($self) = @_;
    my @stacktrace;

    my $tid_msg = '';
    $tid_msg = ' thread ' . $self->{tid} if $self->{tid};

    my $verbosity = defined $self->{verbosity}
                    ? $self->{verbosity}
                    : $self->{defaults}->{verbosity};

    my $ignore_level = defined $self->{ignore_level}
                       ? $self->{ignore_level}
                       : defined $self->{defaults}->{ignore_level}
                         ? $self->{defaults}->{ignore_level}
                         : 0;

    # Skip some packages for first line
    my $level = 0;
    while (my %c = $self->_caller_info($level++)) {
        next if $self->_skip_ignored_package($c{package});
        # Skip ignored levels
        if ($ignore_level > 0) {
            --$ignore_level;
            next;
        };
        push @stacktrace, sprintf " at %s line %s%s",
                              defined $c{file} && $c{file} ne '' ? $c{file} : 'unknown',
                              $c{line} || 0,
                              $tid_msg;
        last;
    };
    # First line have to be filled even if everything was skipped
    if (not @stacktrace) {
        my %c = $self->_caller_info(0);
        push @stacktrace, sprintf " at %s line %s%s",
                              defined $c{file} && $c{file} ne '' ? $c{file} : 'unknown',
                              $c{line} || 0,
                              $tid_msg;
    };
    if ($verbosity >= 3) {
        # Reset the stack trace level only if needed
        if ($verbosity >= 4) {
            $level = 0;
        };
        # Dump the caller stack
        while (my %c = $self->_caller_info($level++)) {
            next if $verbosity == 3 and $self->_skip_ignored_package($c{package});
            push @stacktrace, "\t$c{wantarray}$c{sub_name} called in package $c{package} at $c{file} line $c{line}";
        };
        # Dump the propagated stack
        foreach (@{ $self->{propagated_stack} }) {
            my ($package, $file, $line) = @$_;
            # Skip ignored package
            next if $verbosity <= 3 and $self->_skip_ignored_package($package);
            push @stacktrace, sprintf "\t...propagated in package %s at %s line %d.",
                                  $package,
                                  defined $file && $file ne '' ? $file : 'unknown',
                                  $line || 0;
        };
    };

    return wantarray ? @stacktrace : join("\n", @stacktrace) . "\n";
}


# Propagate exception if it is rethrown
sub PROPAGATE {
    my ($self) = @_;

    # Fill propagate stack
    my $level = 1;
    while (my @c = caller($level++)) {
            # Skip own package
            next if ! defined $Isa_Package{$c[0]} ? $Isa_Package{$c[0]} = do { local $@; local $SIG{__DIE__}; eval { $c[0]->isa(__PACKAGE__) } } : $Isa_Package{$c[0]};
            # Collect the caller stack
            push @{ $self->{propagated_stack} }, [ @c[0..2] ];
            last;
    }

    return $self;
}


# Collect system data and fill the attributes and caller stack.
sub _collect_system_data {
    my ($self) = @_;

    # Collect system data only if verbosity is meaning
    my $verbosity = defined $self->{verbosity} ? $self->{verbosity} : $self->{defaults}->{verbosity};
    if ($verbosity >= 2) {
        $self->{time} = CORE::time();
        $self->{tid}  = threads->tid if defined &threads::tid;
        @{$self}{qw < pid uid euid gid egid >} =
                (     $$, $<, $>,  $(, $)    );

        # Collect stack info
        my @caller_stack;
        my $level = 1;
        while (my @c = do { package DB; caller($level++) }) {
            # Skip own package
            next if ! defined $Isa_Package{$c[0]} ? $Isa_Package{$c[0]} = do { local $@; local $SIG{__DIE__}; eval { $c[0]->isa(__PACKAGE__) } } : $Isa_Package{$c[0]};
            # Collect the caller stack
            my @args = @DB::args;
            if (_HAVE_SCALAR_UTIL_WEAKEN) {
                foreach (@args) {
                    Scalar::Util::weaken($_) if ref $_;
                };
            };
            my $stacktrace_element = [ @c[0 .. 7], @args ];
            push @caller_stack, $stacktrace_element;
            # Collect only one entry if verbosity is lower than 3
            last if $verbosity == 2;
        };
        $self->{caller_stack} = \@caller_stack;
    };

    return $self;
}


# Check if package should be ignored
sub _skip_ignored_package {
    my ($self, $package) = @_;

    my $ignore_package = defined $self->{ignore_package}
                     ? $self->{ignore_package}
                     : $self->{defaults}->{ignore_package};

    my $ignore_class = defined $self->{ignore_class}
                     ? $self->{ignore_class}
                     : $self->{defaults}->{ignore_class};

    if (defined $ignore_package) {
        if (ref $ignore_package eq 'ARRAY') {
            if (@{ $ignore_package }) {
                do { return 1 if defined $_ and (ref $_ eq 'Regexp' and $package =~ $_ or ref $_ ne 'Regexp' and $package eq $_) } foreach @{ $ignore_package };
            }
        }
        else {
            return 1 if ref $ignore_package eq 'Regexp' ? $package =~ $ignore_package : $package eq $ignore_package;
        }
    }
    if (defined $ignore_class) {
        if (ref $ignore_class eq 'ARRAY') {
            if (@{ $ignore_class }) {
                return 1 if grep { do { local $@; local $SIG{__DIE__}; eval { $package->isa($_) } } } @{ $ignore_class };
            }
        }
        else {
            return 1 if do { local $@; local $SIG{__DIE__}; eval { $package->isa($ignore_class) } };
        }
    }

    return '';
}


# Return info about caller. Stolen from Carp
sub _caller_info {
    my ($self, $i) = @_;
    my %call_info;
    my @call_info = ();

    @call_info = @{ $self->{caller_stack}->[$i] }
        if defined $self->{caller_stack} and defined $self->{caller_stack}->[$i];

    @call_info{
        qw< package file line subroutine has_args wantarray evaltext is_require >
    } = @call_info[0..7];

    unless (defined $call_info{package}) {
        return ();
    }

    my $sub_name = $self->_get_subname(\%call_info);
    if ($call_info{has_args}) {
        my @args = map {$self->_format_arg($_)} @call_info[8..$#call_info];
        my $max_arg_nums = defined $self->{max_arg_nums} ? $self->{max_arg_nums} : $self->{defaults}->{max_arg_nums};
        if ($max_arg_nums > 0 and $#args+1 > $max_arg_nums) {
            $#args = $max_arg_nums - 2;
            push @args, '...';
        }
        # Push the args onto the subroutine
        $sub_name .= '(' . join (', ', @args) . ')';
    }
    $call_info{file} = 'unknown' unless $call_info{file};
    $call_info{line} = 0 unless $call_info{line};
    $call_info{sub_name} = $sub_name;
    $call_info{wantarray} = $call_info{wantarray} ? '@_ = ' : '$_ = ';
    return wantarray() ? %call_info : \%call_info;
}


# Figures out the name of the sub/require/eval. Stolen from Carp
sub _get_subname {
    my ($self, $info) = @_;
    if (defined($info->{evaltext})) {
        my $eval = $info->{evaltext};
        if ($info->{is_require}) {
            return "require $eval";
        }
        else {
            $eval =~ s/([\\\'])/\\$1/g;
            return
                "eval '" .
                $self->_str_len_trim($eval, defined $self->{max_eval_len} ? $self->{max_eval_len} : $self->{defaults}->{max_eval_len}) .
                "'";
        }
    }
    return ($info->{subroutine} eq '(eval)') ? 'eval {...}' : $info->{subroutine};
}


# Transform an argument to a function into a string. Stolen from Carp
sub _format_arg {
    my ($self, $arg) = @_;

    return 'undef' if not defined $arg;

    if (do { local $@; local $SIG{__DIE__}; eval { $arg->isa(__PACKAGE__) } } or ref $arg) {
        return q{"} . overload::StrVal($arg) . q{"};
    }

    $arg =~ s/\\/\\\\/g;
    $arg =~ s/"/\\"/g;
    $arg =~ s/`/\\`/g;
    $arg = $self->_str_len_trim($arg, defined $self->{max_arg_len} ? $self->{max_arg_len} : $self->{defaults}->{max_arg_len});

    $arg = "\"$arg\"" unless $arg =~ /^-?[\d.]+\z/;

    no warnings 'utf8';
    if (not defined *utf8::is_utf{CODE} or utf8::is_utf8($arg)) {
        $arg = join('', map { $_ > 255
            ? sprintf("\\x{%04x}", $_)
            : chr($_) =~ /[[:cntrl:]]|[[:^ascii:]]/
                ? sprintf("\\x{%02x}", $_)
                : chr($_)
        } unpack("U*", $arg));
    }
    else {
        $arg =~ s/([[:cntrl:]]|[[:^ascii:]])/sprintf("\\x{%02x}",ord($1))/eg;
    }

    return $arg;
}


# If a string is too long, trims it with ... . Stolen from Carp
sub _str_len_trim {
    my (undef, $str, $max) = @_;
    $max = 0 unless defined $max;
    if ($max > 2 and $max < length($str)) {
        substr($str, $max - 3) = '...';
    }
    return $str;
}


# Modify default values for ATTRS
sub _modify_default {
    my ($self, $key, $value, $modifier) = @_;
    my $class = ref $self ? ref $self : $self;

    # Modify entry in ATTRS constant. Its elements are not constant.
    my $attributes = $class->ATTRS;

    if (not exists $attributes->{$key}->{default}) {
        Exception::Base->throw(
              message => "$class class does not implement default value for `$key' attribute",
              verbosity => 1
        );
    }

    if ($modifier eq '+') {
        my $old = $attributes->{$key}->{default};
        if (ref $old eq 'ARRAY' or ref $value eq 'Regexp') {
            my @new = ref $old eq 'ARRAY' ? @{ $old } : $old;
            foreach my $v (ref $value eq 'ARRAY' ? @{ $value } : $value) {
                next if grep { $v eq $_ } ref $old eq 'ARRAY' ? @{ $old } : $old;
                push @new, $v;
            }
            $attributes->{$key}->{default} = [ @new ];
        }
        elsif ($old =~ /^\d+$/) {
            $attributes->{$key}->{default} += $value;
        }
        else {
            $attributes->{$key}->{default} .= $value;
        }
    }
    elsif ($modifier eq '-') {
        my $old = $attributes->{$key}->{default};
        if (ref $old eq 'ARRAY' or ref $value eq 'Regexp') {
            my @new = ref $old eq 'ARRAY' ? @{ $old } : $old;
            foreach my $v (ref $value eq 'ARRAY' ? @{ $value } : $value) {
                @new = grep { $v ne $_ } @new;
            }
            $attributes->{$key}->{default} = [ @new ];
        }
        elsif ($old =~ /^\d+$/) {
            $attributes->{$key}->{default} -= $value;
        }
        else {
            $attributes->{$key}->{default} = $value;
        }
    }
    else {
        $attributes->{$key}->{default} = $value;
    }

    if (exists $Class_Defaults{$class}) {
        $Class_Attributes{$class}->{$key}->{default}
        = $Class_Defaults{$class}->{$key}
        = $attributes->{$key}->{default};
    }
}


# Create accessors for this class
sub _make_accessors {
    my ($self) = @_;
    my $class = ref $self ? ref $self : $self;

    no warnings 'uninitialized';
    my $attributes = $class->ATTRS;
    foreach my $key (keys %{ $attributes }) {
        next if ref $attributes->{$key} ne 'HASH';
        if (not $class->can($key)) {
            next if not defined $attributes->{$key}->{is};
            if ($attributes->{$key}->{is} eq 'rw') {
                *{_qualify_to_ref($class . '::' . $key)} = sub :lvalue {
                    @_ > 1 ? $_[0]->{$key} = $_[1]
                           : $_[0]->{$key};
                };
            }
            else {
                *{_qualify_to_ref($class . '::' . $key)} = sub {
                    $_[0]->{$key};
                };
            }
        }
    }
}


# Create caller_info() accessors for this class
sub _make_caller_info_accessors {
    my ($self) = @_;
    my $class = ref $self ? ref $self : $self;

    foreach my $key (qw< package file line subroutine >) {
        if (not $class->can($key)) {
            *{_qualify_to_ref($class . '::' . $key)} = sub {
                my $self = shift;
                my $ignore_level = defined $self->{ignore_level}
                                 ? $self->{ignore_level}
                                 : defined $self->{defaults}->{ignore_level}
                                   ? $self->{defaults}->{ignore_level}
                                   : 0;
                my $level = 0;
                while (my %c = $self->_caller_info($level++)) {
                    next if $self->_skip_ignored_package($c{package});
                    # Skip ignored levels
                    if ($ignore_level > 0) {
                        $ignore_level --;
                        next;
                    }
                    return $c{$key};
                }
            };
        }
    }
}


# Load another module without eval q{}
sub _load_package {
    my (undef, $package, $version) = @_;
    return unless $package;

    my $file = $package . '.pm';
    $file =~ s{::}{/}g;

    require $file;

    # Check version if first element on list is a version number.
    if (defined $version and $version =~ m/^\d/) {
        $package->VERSION($version);
    };

    return 1;
};


# Module initialization
UNITCHECK {
    __PACKAGE__->_make_accessors;
    __PACKAGE__->_make_caller_info_accessors;
};


1;


__END__

=begin umlwiki

= Class Diagram =

[                       <<exception>>
                       Exception::Base
 -----------------------------------------------------------------------------
 +ignore_class : ArrayRef                                                {new}
 +ignore_level : Int = 0                                                 {new}
 +ignore_package : ArrayRef                                              {new}
 +max_arg_len : Int = 64                                                 {new}
 +max_arg_nums : Int = 8                                                 {new}
 +max_eval_len : Int = 0                                                 {new}
 +message : Str = "Unknown exception"                                    {new}
 +value : Int = 0                                                        {new}
 +verbosity : Int = 2                                                    {new}
 +caller_stack : ArrayRef
 +egid : Int
 +euid : Int
 +gid : Int
 +pid : Int
 +propagated_stack : ArrayRef
 +tid : Int
 +time : Int
 +uid : Int
 #defaults : HashRef
 #default_attribute : Str = "message"
 #numeric_attribute : Str = "value"
 #eval_attribute : Str = "message"
 #string_attributes : ArrayRef[Str] = ["message"]
 -----------------------------------------------------------------------------
 <<create>> +new( args : Hash )
 <<create>> +throw( args : Hash = undef )
 <<create>> +throw( message : Str, args : Hash = undef )
 +catch() : Exception::Base
 +matches( that : Any ) : Bool                                 {overload="~~"}
 +to_string() : Str                                            {overload='""'}
 +to_number() : Num                                            {overload="0+"}
 +to_bool() : Bool                                           {overload="bool"}
 +get_caller_stacktrace() : Array[Str]|Str
 +PROPAGATE()
 #_collect_system_data()
 #_make_accessors()                                                {unitcheck}
 #_make_caller_info_accessors()                                    {unitcheck}
 <<constant>> +ATTRS() : HashRef                                              ]

=end umlwiki

=head1 IMPORTS

=over

=item use Exception::Base 'I<attribute>' => I<value>;

Changes the default value for I<attribute>.  If the I<attribute> name has no
special prefix, its default value is replaced with a new I<value>.

  use Exception::Base verbosity => 4;

If the I<attribute> name starts with "B<+>" or "B<->" then the new I<value>
is based on previous value:

=over

=item *

If the original I<value> was a reference to array, the new I<value> can
be included or removed from original array.  Use array reference if you
need to add or remove more than one element.

  use Exception::Base
      "+ignore_packages" => [ __PACKAGE__, qr/^Moose::/ ],
      "-ignore_class" => "My::Good::Class";

=item *

If the original I<value> was a number, it will be incremeted or
decremented by the new I<value>.

  use Exception::Base "+ignore_level" => 1;

=item *

If the original I<value> was a string, the new I<value> will be
included.

  use Exception::Base "+message" => ": The incuded message";

=back

=item use Exception::Base 'I<Exception>', ...;

Loads additional exception class module.  If the module is not available,
creates the exception class automatically at compile time.  The newly created
class will be based on B<Exception::Base> class.

  use Exception::Base qw< Exception::Custom Exception::SomethingWrong >;
  Exception::Custom->throw;

=item use Exception::Base 'I<Exception>' => { isa => I<BaseException>, version => I<version>, ... };

Loads additional exception class module.  If the module's version is lower
than given parameter or the module can't be loaded, creates the exception
class automatically at compile time.  The newly created class will be based on
given class and has the given $VERSION variable.

=over

=item isa

The newly created class will be based on given class.

=item version

The class will be created only if the module's version is lower than given
parameter and will have the version given in the argument.

=item has

The class will contain new rw attibute (if parameter is a string) or
attributes (if parameter is a reference to array of strings).

=item message

=item verbosity

=item max_arg_len

=item max_arg_nums

=item max_eval_len

=item I<other attribute having default property>

The class will have the default property for the given attribute.

=back

  use Exception::Base
    'Exception::IO',
    'Exception::FileNotFound' => { isa => 'Exception::IO',
                                   has => [ 'filename' ] },
    'Exception::My' => { version => 0.2 },
    'Exception::WithDefault' => { message => 'Default message' };
  eval { Exception::FileNotFound->throw( filename=>"/foo/bar" ); };
  if ($@) {
    my $e = Exception::Base->catch;
    if ($e->isa('Exception::IO')) { warn "can be also FileNotFound"; }
    if ($e->isa('Exception::My')) { print $e->VERSION; }
  }

=back

=head1 CONSTANTS

=over

=item ATTRS

Declaration of class attributes as reference to hash.

The attributes are listed as I<name> => {I<properties>}, where I<properties> is a
list of attribute properties:

=over

=item is

Can be 'rw' for read-write attributes or 'ro' for read-only attributes.  The
attribute is read-only and does not have an accessor created if 'is' property
is missed.

=item default

Optional property with the default value if the attribute value is not
defined.

=back

The read-write attributes can be set with B<new> constructor.  Read-only
attributes and unknown attributes are ignored.

The constant have to be defined in derivered class if it brings additional
attributes.

  package Exception::My;
  our $VERSION = 0.01;
  use base 'Exception::Base';

  # Define new class attributes
  use constant ATTRS => {
    %{Exception::Base->ATTRS},       # base's attributes have to be first
    readonly  => { is=>'ro' },                   # new ro attribute
    readwrite => { is=>'rw', default=>'blah' },  # new rw attribute
  };

  package main;
  use Exception::Base ':all';
  eval {
    Exception::My->throw( readwrite => 2 );
  };
  if ($@) {
    my $e = Exception::Base->catch;
    print $e->readwrite;                # = 2
    print $e->defaults->{readwrite};    # = "blah"
  }

=back

=head1 ATTRIBUTES

Class attributes are implemented as values of blessed hash.  The attributes
are also available as accessors methods.

=over

=item message (rw, default: 'Unknown exception')

Contains the message of the exception.  It is the part of the string
representing the exception object.

  eval { Exception::Base->throw( message=>"Message" ); };
  print $@->message if $@;

=item value (rw, default: 0)

Contains the value which represents numeric value of the exception object in
numeric context.

  eval { Exception::Base->throw( value=>2 ); };
  print "Error 2" if $@ == 2;

=item verbosity (rw, default: 2)

Contains the verbosity level of the exception object.  It allows to change the
string representing the exception object.  There are following levels of
verbosity:

=over 2

=item 0

Empty string

=item 1

 Message

=item 2

 Message at %s line %d.

The same as the standard output of die() function.  This is the default
option.

=item 3

 Class: Message at %s line %d
         %c_ = %s::%s() called in package %s at %s line %d
         ...propagated in package %s at %s line %d.
 ...

The output contains full trace of error stack without first B<ignore_level>
lines and those packages which are listed in B<ignore_package> and
B<ignore_class> settings.

=item 4

The output contains full trace of error stack.  In this case the
B<ignore_level>, B<ignore_package> and B<ignore_class> settings are meaning
only for first line of exception's message.

=back

If the verbosity is undef, then the default verbosity for exception objects is
used.

If the verbosity set with constructor (B<new> or B<throw>) is lower than 3,
the full stack trace won't be collected.

If the verbosity is lower than 2, the full system data (time, pid, tid, uid,
euid, gid, egid) won't be collected.

This setting can be changed with import interface.

  use Exception::Base verbosity => 4;

It can be also changed for Perl interpreter instance, i.e. for debugging
purposes.

  sh$ perl -MException::Base=verbosity,4 script.pl

=item ignore_package (rw)

Contains the name (scalar or regexp) or names (as references array) of
packages which are ignored in error stack trace.  It is useful if some package
throws an exception but this module shouldn't be listed in stack trace.

  package My::Package;
  use Exception::Base;
  sub my_function {
    do_something() or throw Exception::Base ignore_package=>__PACKAGE__;
    throw Exception::Base ignore_package => [ "My", qr/^My::Modules::/ ];
  }

This setting can be changed with import interface.

  use Exception::Base ignore_package => __PACKAGE__;

=item ignore_class (rw)

Contains the name (scalar) or names (as references array) of packages which
are base classes for ignored packages in error stack trace.  It means that
some packages will be ignored even the derived class was called.

  package My::Package;
  use Exception::Base;
  Exception::Base->throw( ignore_class => "My::Base" );

This setting can be changed with import interface.

  use Exception::Base ignore_class => "My::Base";

=item ignore_level (rw)

Contains the number of level on stack trace to ignore.  It is useful if some
package throws an exception but this module shouldn't be listed in stack
trace.  It can be used with or without I<ignore_package> attribute.

  # Convert warning into exception. The signal handler ignores itself.
  use Exception::Base 'Exception::My::Warning';
  $SIG{__WARN__} = sub {
    Exception::My::Warning->throw( message => $_[0], ignore_level => 1 );
  };

=item time (ro)

Contains the timestamp of the thrown exception.  Collected if the verbosity on
throwing exception was greater than 1.

  eval { Exception::Base->throw( message=>"Message" ); };
  print scalar localtime $@->time;

=item pid (ro)

Contains the PID of the Perl process at time of thrown exception.  Collected
if the verbosity on throwing exception was greater than 1.

  eval { Exception::Base->throw( message=>"Message" ); };
  kill 10, $@->pid;

=item tid (ro)

Constains the tid of the thread or undef if threads are not used.  Collected
if the verbosity on throwing exception was greater than 1.

=item uid (ro)

=item euid (ro)

=item gid (ro)

=item egid (ro)

Contains the real and effective uid and gid of the Perl process at time of
thrown exception.  Collected if the verbosity on throwing exception was
greater than 1.

=item caller_stack (ro)

Contains the error stack as array of array with informations about caller
functions.  The first 8 elements of the array's row are the same as first 8
elements of the output of B<caller> function.  Further elements are optional
and are the arguments of called function.  Collected if the verbosity on
throwing exception was greater than 1.  Contains only the first element of
caller stack if the verbosity was lower than 3.

If the arguments of called function are references and
C<L<Scalar::Util>::weaken> function is available then reference is weakened.

  eval { Exception::Base->throw( message=>"Message" ); };
  ($package, $filename, $line, $subroutine, $hasargs, $wantarray,
  $evaltext, $is_require, @args) = $@->caller_stack->[0];

=item propagated_stack (ro)

Contains the array of array which is used for generating "...propagated at"
message.  The elements of the array's row are the same as first 3 elements of
the output of B<caller> function.

=item max_arg_len (rw, default: 64)

Contains the maximal length of argument for functions in backtrace output.
Zero means no limit for length.

  sub a { Exception::Base->throw( max_arg_len=>5 ) }
  a("123456789");

=item max_arg_nums (rw, default: 8)

Contains the maximal number of arguments for functions in backtrace output.
Zero means no limit for arguments.

  sub a { Exception::Base->throw( max_arg_nums=>1 ) }
  a(1,2,3);

=item max_eval_len (rw, default: 0)

Contains the maximal length of eval strings in backtrace output.  Zero means
no limit for length.

  eval "Exception->throw( max_eval_len=>10 )";
  print "$@";

=item defaults

Meta-attribute contains the list of default values.

  my $e = Exception::Base->new;
  print defined $e->{verbosity}
    ? $e->{verbosity}
    : $e->{defaults}->{verbosity};

=item default_attribute (default: 'message')

Meta-attribute contains the name of the default attribute.  This attribute
will be set for one argument throw method.  This attribute has meaning for
derived classes.

  use Exception::Base 'Exception::My' => {
      has => 'myattr',
      default_attribute => 'myattr',
  };

  eval { Exception::My->throw("string") };
  print $@->myattr;    # "string"

=item numeric_attribute (default: 'value')

Meta-attribute contains the name of the attribute which contains numeric value
of exception object.  This attribute will be used for representing exception
in numeric context.

  use Exception::Base 'Exception::My' => {
      has => 'myattr',
      numeric_attribute => 'myattr',
  };

  eval { Exception::My->throw(myattr=>123) };
  print 0 + $@;    # 123

=item eval_attribute (default: 'message')

Meta-attribute contains the name of the attribute which is filled if error
stack is empty.  This attribute will contain value of B<$@> variable.  This
attribute has meaning for derived classes.

  use Exception::Base 'Exception::My' => {
      has => 'myattr',
      eval_attribute => 'myattr'
  };

  eval { die "string" };
  print $@->myattr;    # "string"

=item string_attributes (default: ['message'])

Meta-attribute contains the array of names of attributes with defined value
which are joined to the string returned by B<to_string> method.  If none of
attributes are defined, the string is created from the first default value of
attributes listed in the opposite order.

  use Exception::Base 'Exception::My' => {
      has => 'myattr',
      myattr => 'default',
      string_attributes => ['message', 'myattr'],
  };

  eval { Exception::My->throw( message=>"string", myattr=>"foo" ) };
  print $@->myattr;    # "string: foo"

  eval { Exception::My->throw() };
  print $@->myattr;    # "default"

=back

=head1 OVERLOADS

=over

=item Boolean context

True value.  See B<to_bool> method.

  eval { Exception::Base->throw( message=>"Message", value=>123 ) };
  if ($@) {
     # the exception object is always true
  }

=item Numeric context

Content of attribute pointed by B<numeric_attribute> attribute.  See
B<to_number> method.

  eval { Exception::Base->throw( message=>"Message", value=>123 ) };
  print 0+$@;           # 123

=item String context

Content of attribute which is combined from B<string_attributes> attributes
with additional informations, depended on B<verbosity> setting.  See
B<to_string> method.

  eval { Exception::Base->throw( message=>"Message", value=>123 ) };
  print "$@";           # "Message at -e line 1.\n"

=item "~~"

Smart matching operator.  See B<matches> method.

  eval { Exception::Base->throw( message=>"Message", value=>123 ) };
  print $@ ~~ "Message";                          # 1
  print $@ ~~ qr/message/i;                       # 1
  print $@ ~~ ['Exception::Base'];                # 1
  print $@ ~~ 123;                                # 1
  print $@ ~~ {message=>"Message", value=>123};   # 1

=back

=head1 CONSTRUCTORS

=over

=item new([%I<args>])

Creates the exception object, which can be thrown later.  The system data
attributes like B<time>, B<pid>, B<uid>, B<gid>, B<euid>, B<egid> are not
filled.

If the key of the argument is read-write attribute, this attribute will be
filled. Otherwise, the argument will be ignored.

  $e = Exception::Base->new(
           message=>"Houston, we have a problem",
           unknown_attr => "BIG"
       );
  print $e->{message};

The constructor reads the list of class attributes from ATTRS constant
function and stores it in the internal cache for performance reason.  The
defaults values for the class are also stored in internal cache.

=item throw([%I<args>]])

Creates the exception object and immediately throws it with B<die> system
function.

  open my $fh, $file
    or Exception::Base->throw( message=>"Can not open file: $file" );

The B<throw> is also exported as a function.

  open my $fh, $file
    or throw 'Exception::Base' => message=>"Can not open file: $file";

=back

The B<throw> can be also used as a method.

=head1 METHODS

=over

=item throw([%I<args>])

Immediately throws exception object.  It can be used for rethrowing existing
exception object.  Additional arguments will override the attributes in
existing exception object.

  $e = Exception::Base->new;
  # (...)
  $e->throw( message=>"thrown exception with overriden message" );

  eval { Exception::Base->throw( message=>"Problem", value=>1 ) };
  $@->throw if $@->value;

=item throw(I<message>, [%I<args>])

If the number of I<args> list for arguments is odd, the first argument is a
message.  This message can be overriden by message from I<args> list.

  Exception::Base->throw( "Problem", message=>"More important" );
  eval { die "Bum!" };
  Exception::Base->throw( $@, message=>"New message" );

=item I<CLASS>-E<gt>throw($I<exception>, [%I<args>])

Immediately rethrows an existing exception object as an other exception class.

  eval { open $f, "w", "/etc/passwd" or Exception::System->throw };
  # convert Exception::System into Exception::Base
  Exception::Base->throw($@);

=item to_string

Returns the string representation of exception object.  It is called
automatically if the exception object is used in string scalar context.  The
method can be used explicity.

  eval { Exception::Base->throw; };
  $@->{verbosity} = 1;
  print "$@";
  $@->verbosity = 4;
  print $@->to_string;

=item to_number

Returns the numeric representation of exception object.  It is called
automatically if the exception object is used in numeric scalar context.  The
method can be used explicity.

  eval { Exception::Base->throw( value => 42 ); };
  print 0+$@;           # 42
  print $@->to_number;  # 42

=item to_bool

Returns the boolean representation of exception object.  It is called
automatically if the exception object is used in boolean context.  The method
can be used explicity.

  eval { Exception::Base->throw; };
  print "ok" if $@;           # ok
  print "ok" if $@->to_bool;  # ok

=item matches(I<that>)

Checks if the exception object matches the given argument.  The B<matches>
method overloads B<~~> smart matching operator, so it can be used with
B<given> keyword.

  my $e = Exception::Base->new( message=>"Message", value=>123 );
  given ($e) {
    when( "Message" ) { ... }                             # matches
    when( qr/message/i ) { ... }                          # matches
    when( ["Exception::Base"] ) { ... }                   # matches
    when( ["Exception::Foo", "Exception::Bar"] ) { ... }  # doesn't
    when( { message=>"Message" } ) { ... }                # matches
    when( { value=>123 } ) { ... }                        # matches
    when( { message=>"Message", value=>45 } ) { ... }     # doesn't
    when( { uid=>0 } ) { ... }  # matches if runs with root privileges
  }

If the argument is a reference to array, it is checked if the object is a
given class.

  use Exception::Base
    'Exception::Simple',
    'Exception::Complex' => { isa => 'Exception::Simple };
  eval { Exception::Complex->throw() };
  print $@ ~~ ['Exception::Base'];                        # matches
  print $@ ~~ ['Exception::Simple', 'Exception::Other'];  # matches
  print $@ ~~ ['NullObject'];                             # doesn't

If the argument is a reference to hash, attributes of the exception
object is matched.

  eval { Exception::Base->throw( message=>"Message", value=>123 ) };
  print $@ ~~ { message=>"Message" };             # matches
  print $@ ~~ { value=>123 };                     # matches
  print $@ ~~ { message=>"Message", value=>45 };  # doesn't

If the argument is a single string, regexp or code reference or is undefined,
the default attribute of the exception object is matched (usually it is a
"message" attribute).

  eval { Exception::Base->throw( message=>"Message" ) };
  print $@ ~~ "Message";                          # matches
  print $@ ~~ qr/Message/;                        # matches
  print $@ ~~ qr/[0-9]/;                          # doesn't
  print $@ ~~ sub{/Message/};                     # matches
  print $@ ~~ sub{0};                             # doesn't
  print $@ ~~ undef;                              # doesn't

If argument is a numeric value, the argument matches if B<value> attribute
matches.

  eval { Exception::Base->throw( value=>123, message=>456 ) };
  print $@ ~~ 123;                                # matches
  print $@ ~~ 456;                                # doesn't

The B<match> method matches for special keywords:

=over

=item -isa

Matches if the object is a given class.

  eval { Exception::Base->new( message=>"Message" ) };
  print $@ ~~ { -isa=>"Exception::Base" };            # matches
  print $@ ~~ { -isa=>["X::Y", "Exception::Base"] };  # matches

=item -has

Matches if the object has a given attribute.

  eval { Exception::Base->new( message=>"Message" ) };
  print $@ ~~ { -has=>"Message" };                    # matches

=item -default

Matches against the default attribute, usually the B<message> attribute.

  eval { Exception::Base->new( message=>"Message" ) };
  print $@ ~~ { -default=>"Message" };                # matches

=back

=item I<CLASS>-E<gt>catch

The exception is recovered from B<$@> variable and method returns an exception
object if exception is caught or undefined value otherwise.  The B<$@>
variable is replaced with empty string to avoid endless loop.

  eval { Exception::Base->throw; };
  if ($@) {
      my $e = Exception::Base->catch;
      print $e->to_string;
  }

If the value is not empty and does not contain the B<Exception::Base> object,
new exception object is created with class I<CLASS> and its message is based
on previous value with removed C<" at file line 123."> string and the last end
of line (LF).

  eval { die "Died\n"; };
  my $e = Exception::Base->catch;
  print ref $e;   # "Exception::Base"

=item get_caller_stacktrace

Returns an array of strings or string with caller stack trace.  It is
implicity used by B<to_string> method.

=item PROPAGATE

Checks the caller stack and fills the B<propagated_stack> attribute.  It is
usually used if B<die> system function was called without any arguments.

=item package

Returns the package name of the subroutine which thrown an exception.

=item file

Returns the file name of the subroutine which thrown an exception.

=item line

Returns the line number for file of the subroutine which thrown an exception.

=item subroutine

Returns the subroutine name which thrown an exception.

=back

=head1 PRIVATE METHODS

=over

=item _collect_system_data

Collects system data and fills the attributes of exception object.  This
method is called automatically if exception if thrown.  It can be used by
derived class.

  package Exception::Special;
  use base 'Exception::Base';
  use constant ATTRS => {
    %{Exception::Base->ATTRS},
    'special' => { is => 'ro' },
  };
  sub _collect_system_data {
    my $self = shift;
    $self->SUPER::_collect_system_data(@_);
    $self->{special} = get_special_value();
    return $self;
  }
  INIT {
    __PACKAGE__->_make_accessors;
  }
  1;

Method returns the reference to the self object.

=item _make_accessors

Creates accessors for each attribute.  This static method should be called in
each derived class which defines new attributes.

  package Exception::My;
  # (...)
  INIT {
    __PACKAGE__->_make_accessors;
  }

=back

=head1 PRIVATE FUNCTIONS

=over

=item _qualify_to_ref

See C<L<Symbol>::qualify_to_ref> function.

=back

=head1 SEE ALSO

There are more implementation of exception objects available on CPAN.  Please
note that Perl has built-in implementation of pseudo-exceptions:

  eval { die { message => "Pseudo-exception", package => __PACKAGE__,
               file => __FILE__, line => __LINE__ };
  };
  if ($@) {
    print $@->{message}, " at ", $@->{file}, " in line ", $@->{line}, ".\n";
  }

The more complex implementation of exception mechanism provides more features.

=over

=item L<Error>

Complete implementation of try/catch/finally/otherwise mechanism.  Uses nested
closures with a lot of syntactic sugar.  It is slightly faster than
B<Exception::Base> module for failure scenario and is much slower for success
scenario.  It doesn't provide a simple way to create user defined exceptions.
It doesn't collect system data and stack trace on error.

=item L<Exception::Class>

More perl-ish way to do OO exceptions.  It is similar to B<Exception::Base>
module and provides similar features but it is 10x slower for failure
scenario.

=item L<Exception::Class::TryCatch>

Additional try/catch mechanism for L<Exception::Class>.  It is 15x slower for
success scenario.

=item L<Class::Throwable>

Elegant OO exceptions similar to B<Exception::Class> and B<Exception::Base>.
It might be missing some features found in B<Exception::Base> and
L<Exception::Class>.

=item L<Exceptions>

Not recommended.  Abadoned.  Modifies %SIG handlers.

=back

The B<Exception::Base> does not depend on other modules like
L<Exception::Class> and it is more powerful than L<Class::Throwable>.  Also it
does not use closures as L<Error> and does not polute namespace as
L<Exception::Class::TryCatch>.  It is also much faster than
L<Exception::Class::TryCatch> and L<Error> for success scenario.

The B<Exception::Base> is also a base class for enchanced classes:

=over

=item L<Exception::System>

The exception class for system or library calls which modifies B<$!> variable.

=item L<Exception::Died>

The exception class for eval blocks with simple L<perlfunc/die>.  It can also
handle L<$SIG{__DIE__}|perlvar/%SIG> hook and convert simple L<perlfunc/die>
into an exception object.

=item L<Exception::Warning>

The exception class which handle L<$SIG{__WARN__}|pervar/%SIG> hook and
convert simple L<perlfunc/warn> into an exception object.

=back

=head1 EXAMPLES

=head2 New exception classes

The B<Exception::Base> module allows to create new exception classes easly.
You can use B<import> interface or L<base> module to do it.

The B<import> interface allows to create new class with new read-write
attributes.

  package Exception::Simple;
  use Exception::Base (__PACKAGE__) => {
    has => qw< reason method >,
    string_attributes => qw< message reason method >,
  };

For more complex exceptions you can redefine B<ATTRS> constant.

  package Exception::Complex;
  use base 'Exception::Base';
  use constant ATTRS => {
    %{ Exception::Base->ATTRS },     # SUPER::ATTRS
    hostname => { is => 'ro' },
    string_attributes => qw< hostname message >,
  };
  sub _collect_system_data {
    my $self = shift;
    my $hostname = `hostname`;
    chomp $hostname;
    $self->{hostname} = $hostname;
    return $self->SUPER::_collect_system_data(@_);
  }

=head1 PERFORMANCE

There are two scenarios for "eval" block: success or failure.  Success
scenario should have no penalty on speed.  Failure scenario is usually more
complex to handle and can be significally slower.

Any other code than simple "if ($@)" is really slow and shouldn't be used if
speed is important.  It means that L<Error> and L<Exception::Class::TryCatch>
should be avoided as far as they are slow by design.  The L<Exception::Class>
module doesn't use "if ($@)" syntax in its documentation so it was benchmarked
with its default syntax, however it might be possible to convert it to simple
"if ($@)".

The B<Exception::Base> module was benchmarked with other implementations for
simple try/catch scenario.  The results (Perl 5.10 i686-linux-thread-multi)
are following:

  -----------------------------------------------------------------------
  | Module                              | Success       | Failure       |
  -----------------------------------------------------------------------
  | eval/die string                     |      859644/s |      232952/s |
  -----------------------------------------------------------------------
  | eval/die object                     |      891294/s |      125992/s |
  -----------------------------------------------------------------------
  | Exception::Base eval/if             |      886204/s |        7585/s |
  -----------------------------------------------------------------------
  | Exception::Base eval/if verbosity=1 |      882376/s |       13778/s |
  -----------------------------------------------------------------------
  | Error                               |       85800/s |       19723/s |
  -----------------------------------------------------------------------
  | Class::Throwable                    |      878963/s |        7461/s |
  -----------------------------------------------------------------------
  | Exception::Class                    |      345114/s |        1278/s |
  -----------------------------------------------------------------------
  | Exception::Class::TryCatch          |      210389/s |        1259/s |
  -----------------------------------------------------------------------

The B<Exception::Base> module was written to be as fast as it is
possible.  It does not use internally i.e. accessor functions which are
slower about 6 times than standard variables.  It is slower than pure
die/eval because it is uses OO mechanisms which are slow in Perl.  It
can be a litte faster if some features are disables, i.e. the stack
trace and higher verbosity.

You can find the benchmark script in this package distribution.

=head1 BUGS

If you find the bug, please report it.

=for readme continue

=head1 AUTHOR

Piotr Roszatycki E<lt>dexter@debian.orgE<gt>

=head1 LICENSE

Copyright (C) 2007, 2008 by Piotr Roszatycki E<lt>dexter@debian.orgE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>
