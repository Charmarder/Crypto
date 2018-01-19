#
#===============================================================================
#
#         FILE: Logger.pm
#
#  DESCRIPTION: Log::Log4perl wrapper
#
#        FILES: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Charmarder
#      COMPANY: HeadStudio
#      VERSION: 1.0
#      CREATED: 2/15/2012 13:55:47
#      CHANGED:  $Date$
#   CHANGED BY:  $Author$
#     REVISION:  $Rev$
#===============================================================================
package Util::Logger;

use strict;
use warnings;
use Log::Log4perl qw(:levels);
use Data::Dumper;

=head1 NAME

Util::Logger - the module is wrapper for Log::Log4perl

=head1 SYNOPSIS

    use use Util::Logger qw($log);

    # init logger
    log = Util::Logger->init({
        'RootDir'     => $ENV{"ROOT_DIR"},
        'LogConfig'   => 'default.log',

    });

    # or (%LogLevel% should be defined in system config file)
    log = Util::Logger->init({
        'RootDir'           => $ENV{"ROOT_DIR"},
        'LogConfigString'   => qq(
            log4perl.logger = DEBUG, Screen

            log4perl.appender.Screen = Log::Dispatch::Screen
            log4perl.appender.Screen.mode = append
            log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
            log4perl.appender.Screen.layout.ConversionPattern = $Util::Logger::DEFAULT_SCREEN_LAYOUT
    
            log4perl.appender.File = Log::Dispatch::FileRotate
            log4perl.appender.File.filename = /tmp/var/default.log
            log4perl.appender.File.mode = append
            log4perl.appender.File.size = 10485760
            log4perl.appender.File.max = 6
            log4perl.appender.File.layout = Log::Log4perl::Layout::PatternLayout
            log4perl.appender.File.layout.ConversionPattern = $Util::Logger::DEFAULT_FILE_LAYOUT
        ),

    });
    

    $log->fatal("this is a fatal");
    $log->error("this is an error");
    $log->warn("this is a warn");
    $log->info("this is an info");
    $log->debug("this is a debug");
    $log->trace("this is a trace");

=head1 DESCRIPTION

    use use Util::Logger qw($log);

This module export package variable $log and by default assigns it to the logger for the current package.
It is equivalent to:

    our $log = Util::Logger->get_logger(__PACKAGE__);

In general, to get a logger for a specified category:

    my $log = Util::Logger->get_logger($category);

=cut 

our $initialized = 0;
our $DEFAULT_SCREEN_LAYOUT = '%-5p -- %M(%L) -- %m%n';
our $DEFAULT_FILE_LAYOUT   = '%d{dd-MM-yyyy HH:mm:ss Z} -- %-5p -- %M(%L) -- %m%n';

my $default_logconfig = qq(
    screen_layout  = $DEFAULT_SCREEN_LAYOUT
    logfile_layout = $DEFAULT_FILE_LAYOUT

    log4perl.logger = INFO, Screen

    log4perl.appender.Screen = Log::Dispatch::Screen
    log4perl.appender.Screen.mode = append
    log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Screen.layout.ConversionPattern = \${screen_layout}
);


=head2 Functions 

=over 12

=item C<import>

Parse parameters passed to 'use Util::Logger'. Only one support - $log.
Usage: use Util::Logger qw($log);

=back

=cut 
sub import {
    my $class = shift;

    # die if no to export
    die "Invalid usage! Correct usage: use " . __PACKAGE__ . " qw(\$log);" unless (scalar @_);

    foreach my $param (@_) {
        if ( $param eq '$log' ) {
            my $log = $class->_init_default();
            no strict 'refs';
            *{ caller() . '::log'} = \$log;
        }
        else {
            die "Invalid import '$param' - valid imports are '\$log'";
        }
    } 
}


=over 12

=item C<_init_default>

Arguments: none

Initialize and return logger by default for the current package.

=back

=cut 
sub _init_default () {

    # init logger if Log::Log4perl not initialized
    if(!Log::Log4perl->initialized()) {
        Log::Log4perl->easy_init({
            level  => $WARN,
            utf8   => 1,
            layout => $DEFAULT_SCREEN_LAYOUT,
        });
    }

    # get logger and return it
    return Log::Log4perl->get_logger(caller(1));
}

=over 12

=item C<init($options, $cfg)>

Arguments: 2
    $options - hashref with log options;
    $cfg  - system config file, Config::Inifiles object (optinal);

The $options may contain the following attributes:
    RootDir              : Root Directory
    DefaultConfigSection : The global default section, by default 'Global'
    LogConfig            : Location of log configuration file
    LogConfigString      : Log config as string
    MDCVars              : Comma separated MDC names of variables to add to Log4perls MDC. 
    MDCName              : MDCName is one of names from MDCVars and contains MDC value
    NDCVars              : NDC value to add to Log4perls NDC, only one supported
    LogCategory          : Log category

The following options will get from $cfg, if they were not defined in $opts:
    LogConfig
    MDCVars
    MDCName
    NDCVar

Initialize and return logger for the caller package function.

=back

=cut 
sub init ($;$) {
    my $class   = (ref $_[0] eq "HASH") ? undef : shift;
    my $options = @_ ? shift : undef;
    my $cfg     = @_ ? shift : undef;

    my $config_section = $options->{DefaultConfigSection} || 'Global';

    my $rootdir = $options->{RootDir} || $ENV{ROOT_DIR}; 
    return undef if ( ! defined($rootdir) ); 

    # define log config as string
    my $logconfig_string;
    my $logconfig_file = $options->{LogConfig} || ( defined($cfg) && $cfg->val($config_section, "LogConfig") ) || "Log4perl.conf";
    $logconfig_file = $rootdir . "/conf/" . $logconfig_file if ( $logconfig_file !~ m{^/|^\.\.}  );
    my $can_be_watched = 0;
    if ( defined($options->{LogConfigString}) ) { 
        $logconfig_string = $options->{LogConfigString};
    }
    elsif( -f $logconfig_file ) { 
        $logconfig_string = do { local( @ARGV, $/ ) = $logconfig_file; <> };
        $can_be_watched = 1;
    } 
    else { 
        $logconfig_string = $default_logconfig;
    }

    # Log::Log4perl  -> Log::Log4perl::Config  ->  Log::Log4perl::Appender ->  Log::Dispatch::FileRotate  ->  Date::Manip ->  
    # -> Date::Manip::TZ  (line 96: $ENV{PATH} = '/bin:/usr/bin';)
    # The path to svn is required. $ENV{PATH} is stored and restored.
    my $PATH = $ENV{PATH};

    # init logger
    if ($can_be_watched) {
        Log::Log4perl->init_and_watch($logconfig_file, 'HUP');
    }
    else {
        Log::Log4perl::init(\$logconfig_string);
    }

    $ENV{PATH} = $PATH;

    $initialized = 1;
    #
    # This is so that even without a standard Config::IniFiles setup, a logger will still be initialized 
    #

    # list of Settings to add to Log4perls MDC
    my $mdc_vars = ( $options->{MDCVars} || ( defined($cfg) && $cfg->val($config_section, "MDCVars") ) || "Id" );
    print Dumper($mdc_vars) if (defined $ENV{'DEBUG'});
    for my $mdc_name ( split(/\s*,\s*/, $mdc_vars ) ) {
        my $mdc_value = ($options->{$mdc_name} || ( defined($cfg) && $cfg->val($config_section, $mdc_name) ) || "No${mdc_name}");
        Log::Log4perl::MDC->put($mdc_name, $mdc_value);
        print STDERR "Added $mdc_name -- ", $mdc_value . " to MDC configuration\n" if (defined $ENV{'DEBUG'});
    } 
    print Dumper(Log::Log4perl::MDC->get_context()) if (defined $ENV{'DEBUG'});

    # NDC value to add to Log4perls NDC
    Log::Log4perl::NDC->remove();
    my $ndc_var = $options->{NDCVar} || ( defined($cfg) && $cfg->val($config_section, "NDCVar") );
    if ( defined $ndc_var ) { 
        Log::Log4perl::NDC->push($ndc_var); 
        print STDERR "Added NDCVar -- " , "$ndc_var to NDC configuration \n" if (defined $ENV{'DEBUG'}); 
    }
    print Log::Log4perl::NDC->get() ."\n" if (defined $ENV{'DEBUG'});

    
    # get logger and return it
    my $category =  $options->{LogCategory} || (caller(1))[3] || 'main';
    return Log::Log4perl->get_logger($category);
}


=over 12

=item C<init_once>

Arguments: 2
    see init()

Initialize logger only if was not initialized by init() function. Return logger.

=back

=cut 
sub init_once ($;$) {
    my ($self, $options, $cfg) = @_;
    my $category = $options->{LogCategory} || (caller(1))[3] || 'main';
    $options->{LogCategory} ||= $category;
    return ($initialized) ? $self->get_logger($category) : $self->init($options, $cfg);
}

=over 12

=item C<get_logger>

Arguments: 1
    $category - log category

Get a logger for a specified category

=back

=cut 
sub get_logger (;$) {
    my $self     = shift;
    my $category = @_ ? shift : ( (caller(1))[3] || 'main' );

    return Log::Log4perl->get_logger($category);
}

=over 12

=item C<suppress_all_log>

This sub suppress all log. 
e.g. During unit testing.

=back

=cut 

sub suppress_all_log {
    init({
        RootDir             => $ENV{ROOT_DIR},
        LogCategory         => 'Testing',
        LogConfigString     => qq(
            log4perl.logger = OFF, Screen
            log4perl.appender.Screen = Log::Dispatch::Screen
            log4perl.appender.Screen.mode = append
            log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
            log4perl.appender.Screen.layout.ConversionPattern = %-5p -- %M(%L) -- %m%n
        ),
    });
}

1;


