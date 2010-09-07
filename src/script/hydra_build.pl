#! /var/run/current-system/sw/bin/perl -w

use strict;
use File::Basename;
use File::stat;
use Hydra::Schema;
use Hydra::Helper::Nix;
use Hydra::Helper::AddBuilds;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use Email::Simple;
use Email::Simple::Creator;
use Sys::Hostname::Long;
use Config::General;
use Text::Table;
use POSIX qw(strftime);
use Net::Twitter::Lite;
use Data::Dump qw(dump);
use Switch;

STDOUT->autoflush();

my $db = openHydraDB;


my %config = new Config::General($ENV{"HYDRA_CONFIG"})->getall;


sub sendTwitterNotification {
    my ($build) = @_;

    return unless (defined $ENV{'TWITTER_USER'} && defined $ENV{'TWITTER_PASS'});

    my $addURL = defined $ENV{'HYDRA_BUILD_BASEURL'};

    my $jobName  = $build->project->name . ":" . $build->jobset->name . ":" . $build->job->name;
    my $status   = $build->resultInfo->buildstatus == 0 ? "SUCCEEDED" : "FAILED";
    my $system   = $build->system;
    my $duration = ($build->resultInfo->stoptime - $build->resultInfo->starttime) . " seconds"; 
    my $url = $ENV{'HYDRA_BUILD_BASEURL'}."/".$build->id ;

    my $nt = Net::Twitter::Lite->new(
        username => $ENV{'TWITTER_USER'},
        password => $ENV{'TWITTER_PASS'},
        clientname => "Hydra Build Daemon"
      );

    my $tag = $build->project->name;
    my $msg = "$jobName ($system): $status in $duration #$tag"; 
    if (length($msg) + 1 + length($url) <= 140) {
      $msg = "$msg $url" ;
    }
    
    eval {
        my $result = eval { $nt->update($msg) };
    };
    warn "$@\n" if $@;
}

sub statusDescription {
    my ($buildstatus) = @_;

    my $status = "Unknown failure";
    switch ($buildstatus) {     
        case 0 { $status = "Success"; }
        case 1 { $status = "Failed with non-zero exit code"; }
        case 2 { $status = "Dependency failed"; }
        case 4 { $status = "Cancelled"; }
    }
    
   return $status;
}

sub sendEmailNotification {
    my ($build) = @_;

    die unless defined $build->resultInfo;
        
    return if ! ( $build->jobset->enableemail && ($build->maintainers ne "" || $build->jobset->emailoverride ne "") );

    # Do we want to send mail?

    my $prevBuild;
    ($prevBuild) = $db->resultset('Builds')->search(
	{ project => $build->project->name
        , jobset => $build->jobset->name
        , job => $build->job->name
        , system => $build->system 
        , finished => 1
        , id => { '!=', $build->id } 
	}, { order_by => ["timestamp DESC"] }

        );

    if (defined $prevBuild && ($build->resultInfo->buildstatus == $prevBuild->resultInfo->buildstatus)) {
        return; 
    }

    # Send mail.
    # !!! should use the Template Toolkit here.

    print STDERR "sending mail notification to ", $build->maintainers, "\n";

    my $jobName = $build->project->name . ":" . $build->jobset->name . ":" . $build->job->name;

    my $status =  statusDescription($build->resultInfo->buildstatus);

    my $baseurl = hostname_long ;
    my $sender = $config{'notification_sender'} ||
        (($ENV{'USER'} || "hydra") .  "@" . $baseurl);

    my $selfURI = $config{'base_uri'} || "http://localhost:3000";

    sub showTime { my ($x) = @_; return strftime('%Y-%m-%d %H:%M:%S', localtime($x)); }

    my $infoTable = Text::Table->new({ align => "left" }, \ " | ", { align => "left" });
    my @lines = (
        [ "Build ID:", $build->id ],
        [ "Nix name:", $build->nixname ],
        [ "Short description:", $build->description || '(not given)' ],
        [ "Maintainer(s):", $build->maintainers ],
        [ "System:", $build->system ],
        [ "Derivation store path:", $build->drvpath ],
        [ "Output store path:", $build->outpath ],
        [ "Time added:", showTime $build->timestamp ],
        );
    push @lines, (
        [ "Build started:", showTime $build->resultInfo->starttime ],
        [ "Build finished:", showTime $build->resultInfo->stoptime ],
        [ "Duration:", $build->resultInfo->stoptime - $build->resultInfo->starttime . "s" ],
    ) if $build->resultInfo->starttime;
    $infoTable->load(@lines);

    my $inputsTable = Text::Table->new(
        { title => "Name", align => "left" }, \ " | ",
        { title => "Type", align => "left" }, \ " | ",
        { title => "Value", align => "left" });
    @lines = ();
    foreach my $input ($build->inputs) {
        my $type = $input->type;
        push @lines,
            [ $input->name
            , $input->type
            , ( $input->type eq "build" || $input->type eq "sysbuild")
              ? $input->dependency->id
              : ($input->type eq "string" || $input->type eq "boolean")
              ? $input->value : ($input->uri . ':' . $input->revision)
            ];
    }
    $inputsTable->load(@lines);

    my $loglines = 50;
    my $logfile = $build->resultInfo->logfile;
    my $logtext = defined $logfile && -e $logfile ? `tail -$loglines $logfile` : "No logfile available.\n";

    my $body = "Hi,\n"
        . "\n"
        . "This is to let you know that Hydra build " . $build->id
        . " of job " . $jobName . " "  . (defined $prevBuild ? "has changed from '".statusDescription($prevBuild->resultInfo->buildstatus)."' to '$status'" : "is '$status'." ) .".\n"
        . "\n"
        . "Complete build information can be found on this page: "
        . "$selfURI/build/" . $build->id . "\n"
        . ($build->resultInfo->buildstatus != 0 ? "\nThe last $loglines lines of the build log are shown at the bottom of this email.\n" : "")
        . "\n"
        . "A summary of the build information follows:\n"
        . "\n"
        . $infoTable->body
        . "\n"
        . "The build inputs were:\n"
        . "\n"
        . $inputsTable->title
        . $inputsTable->rule('-', '+')
        . $inputsTable->body
        . "\n"
        . "Regards,\n\nThe Hydra build daemon.\n"
        . ($build->resultInfo->buildstatus != 0 ? "\n---\n$logtext" : ""); 

    # stripping trailing spaces from lines
    $body =~ s/[\ ]+$//gm;

    my $to = (!$build->jobset->emailoverride eq "") ? $build->jobset->emailoverride : $build->maintainers;
    my $email = Email::Simple->create(
        header => [
            To      => $to,
            From    => "Hydra Build Daemon <$sender>",
            Subject => "Hydra job $jobName build " . $build->id . ": $status",

            'X-Hydra-Instance' => $baseurl,
            'X-Hydra-Project'  => $build->project->name,
            'X-Hydra-Jobset'   => $build->jobset->name,
            'X-Hydra-Job'      => $build->job->name
        ],
        body => "",
    );
    $email->body_set($body);

    print $email->as_string if $ENV{'HYDRA_MAIL_TEST'};

    sendmail($email);
}


sub doBuild {
    my ($build) = @_;

    my $drvPath   = $build->drvpath;
    my $outPath   = $build->outpath;
    my $maxsilent = $build->maxsilent;
    my $timeout   = $build->timeout;

    my $isCachedBuild = 1;
    my $outputCreated = 1; # i.e., the Nix build succeeded (but it could be a positive failure)
    my $startTime = 0;
    my $stopTime = 0;

    my $buildStatus = 0; # = succeeded

    my $errormsg = undef;

    if (!isValidPath($outPath)) {
        $isCachedBuild = 0;

        # Do the build.
        $startTime = time();

        my $thisBuildFailed = 0;
        my $someBuildFailed = 0;
        
        # Run Nix to perform the build, and monitor the stderr output
        # to get notifications about specific build steps, the
        # associated log files, etc.
        my $cmd = "nix-store --realise $drvPath " .
            "--max-silent-time $maxsilent --keep-going --fallback " .
            "--no-build-output --log-type flat --print-build-trace " .
            "--add-root " . gcRootFor $outPath . " 2>&1";

        my $max = $build->buildsteps->find(
            {}, {select => {max => 'stepnr + 1'}, as => ['max']});
        my $buildStepNr = defined $max ? $max->get_column('max') : 1;

        my %buildSteps;
        
        open OUT, "$cmd |" or die;

        while (<OUT>) {
            $errormsg .= $_;
            
            unless (/^@\s+/) {
                print STDERR "$_";
                next;
            }
            
            if (/^@\s+build-started\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/) {
		my $drvPathStep = $1;
                txn_do($db, sub {
                    $build->buildsteps->create(
                        { stepnr => ($buildSteps{$drvPathStep} = $buildStepNr++)
                        , type => 0 # = build
                        , drvpath => $drvPathStep
                        , outpath => $2
                        , system => $3
                        , logfile => $4
                        , busy => 1
                        , starttime => time
                        });
                });
            }
            
            elsif (/^@\s+build-remote\s+(\S+)\s+(\S+)$/) {
                my $drvPathStep = $1;
		my $machine = $2;
                txn_do($db, sub {
                    my $step = $build->buildsteps->find({stepnr => $buildSteps{$drvPathStep}}) or die;
                    $step->update({machine => $machine});
                });
	    }
            
            elsif (/^@\s+build-succeeded\s+(\S+)\s+(\S+)$/) {
                my $drvPathStep = $1;
                txn_do($db, sub {
                    my $step = $build->buildsteps->find({stepnr => $buildSteps{$drvPathStep}}) or die;
                    $step->update({busy => 0, status => 0, stoptime => time});
                });
            }

            elsif (/^@\s+build-failed\s+(\S+)\s+(\S+)\s+(\S+)\s+(.*)$/) {
                my $drvPathStep = $1;
                $someBuildFailed = 1;
                $thisBuildFailed = 1 if $drvPath eq $drvPathStep;
                my $errorMsg = $4;
                $errorMsg = "build failed previously (cached)" if $3 eq "cached";
                txn_do($db, sub {
                    if ($buildSteps{$drvPathStep}) {
                        my $step = $build->buildsteps->find({stepnr => $buildSteps{$drvPathStep}}) or die;
                        $step->update({busy => 0, status => 1, errormsg => $errorMsg, stoptime => time});
                    }
                    # Don't write a record if this derivation already
                    # failed previously.  This can happen if this is a
                    # restarted build.
                    elsif (scalar $build->buildsteps->search({drvpath => $drvPathStep, type => 0, busy => 0, status => 1}) == 0) {
                        $build->buildsteps->create(
                            { stepnr => ($buildSteps{$drvPathStep} = $buildStepNr++)
                            , type => 0 # = build
                            , drvpath => $drvPathStep
                            , outpath => $2
                            , logfile => getBuildLog($drvPathStep)
                            , busy => 0
                            , status => 1
                            , starttime => time
                            , stoptime => time
                            , errormsg => $errorMsg
                            });
                    }
                });
            }

            elsif (/^@\s+substituter-started\s+(\S+)\s+(\S+)$/) {
                my $outPath = $1;
                txn_do($db, sub {
                    $build->buildsteps->create(
                        { stepnr => ($buildSteps{$outPath} = $buildStepNr++)
                        , type => 1 # = substitution
                        , outpath => $1
                        , busy => 1
                        , starttime => time
                        });
                });
            }

            elsif (/^@\s+substituter-succeeded\s+(\S+)$/) {
                my $outPath = $1;
                txn_do($db, sub {
                    my $step = $build->buildsteps->find({stepnr => $buildSteps{$outPath}}) or die;
                    $step->update({busy => 0, status => 0, stoptime => time});
                });
            }

            elsif (/^@\s+substituter-failed\s+(\S+)\s+(\S+)\s+(\S+)$/) {
                my $outPath = $1;
                txn_do($db, sub {
                    my $step = $build->buildsteps->find({stepnr => $buildSteps{$outPath}}) or die;
                    $step->update({busy => 0, status => 1, errormsg => $3, stoptime => time});
                });
            }

            else {
                print STDERR "unknown Nix trace message: $_";
            }
        }
        
        close OUT;

        my $res = $?;

        $stopTime = time();

        if ($res != 0) {
            if ($thisBuildFailed) { $buildStatus = 1; }
            elsif ($someBuildFailed) { $buildStatus = 2; }
            else { $buildStatus = 3; }
        }

        # Only store the output of running Nix if we have a miscellaneous error.
        $errormsg = undef unless $buildStatus == 3;
    }

  done:

    txn_do($db, sub {
        $build->update({finished => 1, timestamp => time});

        my $releaseName = getReleaseName($outPath);
        
        $db->resultset('BuildResultInfo')->create(
            { id => $build->id
            , iscachedbuild => $isCachedBuild
            , buildstatus => $buildStatus
            , starttime => $startTime
            , stoptime => $stopTime
            , logfile => getBuildLog($drvPath)
            , errormsg => $errormsg
            , releasename => $releaseName
            });

        if ($buildStatus == 0) {
            addBuildProducts($db, $build);
        }

        $build->schedulingInfo->delete;
    });

    sendEmailNotification $build;
    sendTwitterNotification $build;
}


my $buildId = $ARGV[0] or die;
print STDERR "performing build $buildId\n";

if ($ENV{'HYDRA_MAIL_TEST'}) {
    sendEmailNotification $db->resultset('Builds')->find($buildId);
    exit 0;
}
if ($ENV{'HYDRA_TWITTER_TEST'}) {
    sendTwitterNotification $db->resultset('Builds')->find($buildId);
    exit 0;
}

# Lock the build.  If necessary, steal the lock from the parent
# process (runner.pl).  This is so that if the runner dies, the
# children (i.e. the build.pl instances) can continue to run and won't
# have the lock taken away.
my $build;
txn_do($db, sub {
    $build = $db->resultset('Builds')->find($buildId);
    die "build $buildId doesn't exist" unless defined $build;
    die "build $buildId already done" if defined $build->resultInfo;
    if ($build->schedulingInfo->busy != 0 && $build->schedulingInfo->locker != getppid) {
        die "build $buildId is already being built";
    }
    $build->schedulingInfo->update({busy => 1, locker => $$});
    $build->buildsteps->search({busy => 1})->delete_all;
    $build->buildproducts->delete_all;
});

die unless $build;

# Do the build.  If it throws an error, unlock the build so that it
# can be retried.
eval {
    doBuild $build;
    print "done\n";
};
if ($@) {
    warn $@;
    txn_do($db, sub {
        $build->schedulingInfo->update({busy => 0, locker => $$});
    });
}
