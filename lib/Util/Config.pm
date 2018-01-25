#
#===============================================================================
#
#         FILE: Config.pm
#
#  DESCRIPTION: Util config functions
#
#        FILES: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Charmarder
#      COMPANY: HeadStudio
#      VERSION: 1.0
#      CREATED: 29.01.2014 18:16:34
#      CHANGED: $Date$
#   CHANGED BY: $Author$
#     REVISION: $Rev$
#===============================================================================

=head1 NAME

Config.pm - Util config functions

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

package Util::Config;
use base 'Exporter';

use strict;
use warnings;

use FindBin qw($Bin $Script);
BEGIN {
    use vars qw($GO);
    our @EXPORT = qw($GO get_config_value);

    # initial $GO init
    $GO = {
        APP_TYPE        => {
            SOAP     =>  exists $ENV{HTTP_SOAPACTION} ? 1              : 0,
            CGI      =>  exists $ENV{HTTP_HOST}       ? 1              : 0,
            MOD_PERL =>  exists $ENV{MOD_PERL}        ? $ENV{MOD_PERL} : 0,
            CONSOLE  => !exists $ENV{HTTP_HOST}       ? 1              : 0,
        },

        # Data formats
        SYSTEM_FULL_DATE_FORMAT  => '%Y-%m-%d %H:%M:%S',
        SYSTEM_DATE_FORMAT       => '%Y-%m-%d',
        SYSTEM_TIME_FORMAT       => '%H:%M:%S',
        USER_FULL_DATE_FORMAT    => '%d.%m.%Y, %H:%M:%S',
        USER_DATE_FORMAT         => '%d.%m.%Y',
        USER_TIME_FORMAT         => '%H:%M:%S',
    };

    if ($GO->{APP_TYPE}->{CGI}) {
        $GO->{SCRIPT_FILENAME} = $ENV{SCRIPT_FILENAME} || $0;
        $GO->{SCRIPT_FILENAME} =~ m/^(.+?)(\w+\.?\w*)$/g;
        $GO->{SCRIPT_PATH}     = $1;
        $GO->{SCRIPT_NAME}     = $2;

        $GO->{SCRIPT_PATH} =~ m/(.*)\/[^\/]*\/[^\/]*\/$/;   # two dir level up
        $GO->{ROOT_DIR} = $1;
    } else {
        $GO->{SCRIPT_FILENAME} = $Bin . '/' . $Script;   # Script file name with path
        $GO->{SCRIPT_PATH}     = $Bin;
        $GO->{SCRIPT_NAME}     = $Script;
    }
}

#use version;
#our $VERSION = qv("2.0");

use Getopt::Long qw(GetOptionsFromString);
use Data::Dumper;
use Config::IniFiles;

use Util::Logger qw($log);


# The absolute path where the 'bin' directory is
$GO->{ROOT_DIR} = &find_root_dir() unless ($GO->{APP_TYPE}->{CGI});


=over

=item C<get_config($options)>

Arguments: 2
  file            - Location of configuration file, by default 'global.conf'
  default_section - The global default section, by default 'Global'

Prepares the Config::Inifiles object infrastructure and return it. 

=cut
sub get_config ($;$) {
    my $file = shift || 'global.conf';
    my $default_section = shift || 'Global';

    $file = $GO->{ROOT_DIR} . "/conf/" . $file if ( $file !~ m{^/.*|^\.\.} );

    my $cfg = Config::IniFiles->new('-file' => $file, '-default' => $default_section) || die $!;

    my $local_cfg = $GO->{ROOT_DIR} . "/conf/local.conf";
    $cfg = Config::IniFiles->new(-file => $local_cfg,  '-default' => $default_section, -import => $cfg) || die $!;

    $log->info("Configuration was successfully initialized from $file");

    return $cfg;
}

=item C<get_config_value($option_name, $section_name)>

Arguments: 4
  option_name  - name of option
  section_name - name of section, by default 'Global'
  substitutes  - refhash with substitute variables
  mode         - 0 - silent, 1 - die, 2 - warn

Return value of option from specified section of config

=cut
sub get_config_value ($;$$$) {
    my $option_name  = shift;
    my $section_name = shift || 'Global';
    my $mode         = (defined $_[0]) ? shift : 2;
    my $substitutes  = shift || {};

    my $option_value = $GO->{CFG}->val($section_name, $option_name);

    if ( !defined $option_value ) {
        # The checking of INITIALIZED is for suppressing warning:
        # "Log4perl: Seems like no initialization happened. Forgot to call init()?"
        # Config module is used for initialization of logger. At this point logger is not initialized yet.
        if (Log::Log4perl->initialized() ) {
            if ($mode == 1) {
                $log->logdie("$option_name is not defined in section $section_name in the configuration.");
            } elsif ($mode == 2) {
                $log->warn("$option_name is not defined in section $section_name in the configuration.");
            }
        }
        return;
    } else {
        # Substitute variable names (%var_name%)
        my @sub_list = ($option_value =~ m/\%(\w+)\%/g);
        foreach my $name (@sub_list) {
            my $sub_value = 
                (defined $substitutes->{$name}) ? $substitutes->{$name} : $GO->{CFG}->val($section_name, $name);
            if ($sub_value) {
                $option_value =~ s/\%$name\%/$sub_value/g;
            } else {
                die "Substitute variable ($name) is not defined in the config and have not passed to."; 
            }
        }
        return $option_value;
    }
}

=item C<init_error()>

Arguments: none

This function is used to wrap error messages

=cut
sub init_error () {
    $SIG{__DIE__} = sub {
    
        if($^S) {
            # We're in an eval {} and don't want log this message but catch it later
            return;
        }
        
        my $err      = shift @_;
        my $longmess = &Carp::longmess;
        
        # Get logger
        local $log = Util::Logger->get_logger('DieLog'); 

        # Increasing it by one will cause it to log the calling function's parameters, not the ones of the signal handler
        local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
          
        my $txt = $GO->{SCRIPT_FILENAME} . ": $err: " . $longmess;
        $log->fatal($txt);
    }; 
}

=item C<find_root_dir()>

Arguments: none

This function returns the absolute path where the 'bin' directory is

=cut
sub find_root_dir() {
    # If $ENV{ROOT_DIR} is defined and correct
    if ( defined $ENV{ROOT_DIR} ) {  
        return $ENV{ROOT_DIR};
    } 
     
    # Finding the absolute path where the 'bin' directory is
    my $current_dir = $Bin;
    until ( -d "$current_dir/bin") {
        $current_dir =~  s!\/\w+$!!;
        last if (!$current_dir);
    }
    
    if (!$current_dir) {
        $log->logdie("Sub 'find_root_dir' return the empty ROOT_DIR");
    } else {
        $log->debug("Sub 'find_root_dir' return the ROOT_DIR = '" . $current_dir . "'");
    }

    return $current_dir;    
}

=item C<get_options($script_options, $cmdline)>

Function get options (command line parameters), put them to $GO->{IN} and check according script options.

Arguments: 2
    $script_options = {     # script options.
        description => 'Short description of the script',   # can be string or ref array of strings
        options     => {    # command line options
            'getopt' => {           # key is value for Getopt::Long::GetOptions()
                info        => '',  # option description, can be string or ref array of strings
                default     => '',  # default value
                mandatory   => 1,   # set to 1 if option mandatory
                pattern     => '',  # regexp pattern
            },
            ...
        },
        examples => [],     # array ref of execution examples for usage function
    };

    Each item of 'options' will be converted to 
            'name' => {         # first word from getopt
                getopt      => '',
                name        => '',  # name of option for usage() function
                info        => '',
                default     => '',
                mandatory   => 1, 
                pattern     => '',
            }

    $cmdline - command line options as string, usualy it come from $ENV{'SSH_ORIGINAL_COMMAND'}

Returns command line options.

=cut
sub get_options {
    my $script_parameters = shift || $GO->{SCRIPT};
    my $cmdline = shift;
    my $options;

    # prepare script options structure for convenient usage
    foreach my $getopt ( keys %{$script_parameters->{options}} ) {
        my $option = $script_parameters->{options}->{$getopt};

        my ($names) = split ('=', $getopt);
        $option->{name} = '--' . join(', -', split ('\|', $names));
        $option->{getopt} = $getopt;

        # get option name and use it as key
        my ($name) = split ('\|', $names);
        $script_parameters->{options}->{$name} = delete $script_parameters->{options}->{$getopt};

        # define default values
        if (defined $script_parameters->{options}->{$name}->{default}) {
            $options->{$name} = $script_parameters->{options}->{$name}->{default};
        }
    }
    $GO->{SCRIPT} = $script_parameters;
#    $log->debug(Dumper $GO->{SCRIPT});
    $log->debug(Dumper $options);
    
    # get option list for GetOption()
    my @option_list = map { $GO->{SCRIPT}->{options}->{$_}->{getopt} } keys %{$GO->{SCRIPT}->{options}};
    $log->debug(Dumper \@option_list);

    # Get options
    if ($cmdline) {
        GetOptionsFromString($cmdline, $options, @option_list) or usage('Invalid arguments.');
    } else {
        GetOptions($options, @option_list) or usage('Invalid arguments.'); 
    }

    # Check options
    foreach my $o (keys %{$GO->{SCRIPT}->{options}}) {
        my $rules = $GO->{SCRIPT}->{options}->{$o};
        if ($rules->{mandatory} && ! defined $options->{$o}) {
            usage("Option $o is mandatory.");
        } elsif ($rules->{pattern} && eval "'$options->{$o}' !~ $rules->{pattern}") {
            usage("Option $o contains illegal characters. (Pattern: $rules->{pattern})");
        }
    }
    
    $GO->{IN} = $options;
    
    return $options;
}

=item C<usage($message)>

Print error message and script usage help

=cut
sub usage {
    local $\ = "\n";
    print STDERR "$_[0]" if @_;
    print STDERR &help;
    exit(1);
}

=item C<help()>

Return help text for printing in usage function

=cut
sub help {
    my @lines;
    
    # add description of script
    if (ref $GO->{SCRIPT}->{description} eq 'ARRAY') {
        map {push @lines, $_} @{ $GO->{SCRIPT}->{description} };
    } else {
        push @lines, (
            "Usage: $Script [OPTIONS]...",
            $GO->{SCRIPT}->{description},
        );
    }

    # add description of available options
    my $options = $GO->{SCRIPT}->{options};
    if (scalar keys %$options) {
        push @lines, (
            '',
            'Available OPTIONS:',
        );

        # find max length of option name
        my $max_length = 0;
        foreach my $o (keys %$options) {
            $max_length = length $options->{$o}->{name} if (length $options->{$o}->{name} > $max_length);
        }

        map {
            my $format = "%-" . ($max_length + 3) . "s %s";
            if (ref $options->{$_}->{info} eq 'ARRAY') {
                push @lines, sprintf($format, $options->{$_}->{name}, shift @{$options->{$_}->{info}});
                map {push @lines, sprintf($format, '', $_)} @{$options->{$_}->{info}};
            } else {
                push @lines, sprintf($format, $options->{$_}->{name}, $options->{$_}->{info}); 
            }
        } (sort keys %$options);
    }

    # add examples of execution
    my $examples = $GO->{SCRIPT}->{examples};
    if (scalar @$examples) {
        push @lines, (
            '', 
            "Examples:",
        );
        map {push @lines, $_} (@$examples);
        push @lines, '';
    }

    return join("\n", @lines);
}

1;

