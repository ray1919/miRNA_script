#!/usr/bin/perl
#line 2 "C:\Perl\site\bin\par.pl"
eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell

package __par_pl;

# --- This script must not use any modules at compile time ---
# use strict;

#line 158

my ($par_temp, $progname, @tmpfile);
END { if ($ENV{PAR_CLEAN}) {
    require File::Temp;
    require File::Basename;
    require File::Spec;
    my $topdir = File::Basename::dirname($par_temp);
    outs(qq{Removing files in "$par_temp"});
    File::Find::finddepth(sub { ( -d ) ? rmdir : unlink }, $par_temp);
    rmdir $par_temp;
    # Don't remove topdir because this causes a race with other apps
    # that are trying to start.

    if (-d $par_temp && $^O ne 'MSWin32') {
        # Something went wrong unlinking the temporary directory.  This
        # typically happens on platforms that disallow unlinking shared
        # libraries and executables that are in use. Unlink with a background
        # shell command so the files are no longer in use by this process.
        # Don't do anything on Windows because our parent process will
        # take care of cleaning things up.

        my $tmp = new File::Temp(
            TEMPLATE => 'tmpXXXXX',
            DIR => File::Basename::dirname($topdir),
            SUFFIX => '.cmd',
            UNLINK => 0,
        );

        print $tmp "#!/bin/sh
x=1; while [ \$x -lt 10 ]; do
   rm -rf '$par_temp'
   if [ \! -d '$par_temp' ]; then
       break
   fi
   sleep 1
   x=`expr \$x + 1`
done
rm '" . $tmp->filename . "'
";
            chmod 0700,$tmp->filename;
        my $cmd = $tmp->filename . ' >/dev/null 2>&1 &';
        close $tmp;
        system($cmd);
        outs(qq(Spawned background process to perform cleanup: )
             . $tmp->filename);
    }
} }

BEGIN {
    Internals::PAR::BOOT() if defined &Internals::PAR::BOOT;

    eval {

_par_init_env();

if (exists $ENV{PAR_ARGV_0} and $ENV{PAR_ARGV_0} ) {
    @ARGV = map $ENV{"PAR_ARGV_$_"}, (1 .. $ENV{PAR_ARGC} - 1);
    $0 = $ENV{PAR_ARGV_0};
}
else {
    for (keys %ENV) {
        delete $ENV{$_} if /^PAR_ARGV_/;
    }
}

my $quiet = !$ENV{PAR_DEBUG};

# fix $progname if invoked from PATH
my %Config = (
    path_sep    => ($^O =~ /^MSWin/ ? ';' : ':'),
    _exe        => ($^O =~ /^(?:MSWin|OS2|cygwin)/ ? '.exe' : ''),
    _delim      => ($^O =~ /^MSWin|OS2/ ? '\\' : '/'),
);

_set_progname();
_set_par_temp();

# Magic string checking and extracting bundled modules {{{
my ($start_pos, $data_pos);
{
    local $SIG{__WARN__} = sub {};

    # Check file type, get start of data section {{{
    open _FH, '<', $progname or last;
    binmode(_FH);

    my $buf;
    seek _FH, -8, 2;
    read _FH, $buf, 8;
    last unless $buf eq "\nPAR.pm\n";

    seek _FH, -12, 2;
    read _FH, $buf, 4;
    seek _FH, -12 - unpack("N", $buf), 2;
    read _FH, $buf, 4;

    $data_pos = (tell _FH) - 4;
    # }}}

    # Extracting each file into memory {{{
    my %require_list;
    while ($buf eq "FILE") {
        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        my $fullname = $buf;
        outs(qq(Unpacking file "$fullname"...));
        my $crc = ( $fullname =~ s|^([a-f\d]{8})/|| ) ? $1 : undef;
        my ($basename, $ext) = ($buf =~ m|(?:.*/)?(.*)(\..*)|);

        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        if (defined($ext) and $ext !~ /\.(?:pm|pl|ix|al)$/i) {
            my ($out, $filename) = _tempfile($ext, $crc);
            if ($out) {
                binmode($out);
                print $out $buf;
                close $out;
                chmod 0755, $filename;
            }
            $PAR::Heavy::FullCache{$fullname} = $filename;
            $PAR::Heavy::FullCache{$filename} = $fullname;
        }
        elsif ( $fullname =~ m|^/?shlib/| and defined $ENV{PAR_TEMP} ) {
            # should be moved to _tempfile()
            my $filename = "$ENV{PAR_TEMP}/$basename$ext";
            outs("SHLIB: $filename\n");
            open my $out, '>', $filename or die $!;
            binmode($out);
            print $out $buf;
            close $out;
        }
        else {
            $require_list{$fullname} =
            $PAR::Heavy::ModuleCache{$fullname} = {
                buf => $buf,
                crc => $crc,
                name => $fullname,
            };
        }
        read _FH, $buf, 4;
    }
    # }}}

    local @INC = (sub {
        my ($self, $module) = @_;

        return if ref $module or !$module;

        my $filename = delete $require_list{$module} || do {
            my $key;
            foreach (keys %require_list) {
                next unless /\Q$module\E$/;
                $key = $_; last;
            }
            delete $require_list{$key} if defined($key);
        } or return;

        $INC{$module} = "/loader/$filename/$module";

        if ($ENV{PAR_CLEAN} and defined(&IO::File::new)) {
            my $fh = IO::File->new_tmpfile or die $!;
            binmode($fh);
            print $fh $filename->{buf};
            seek($fh, 0, 0);
            return $fh;
        }
        else {
            my ($out, $name) = _tempfile('.pm', $filename->{crc});
            if ($out) {
                binmode($out);
                print $out $filename->{buf};
                close $out;
            }
            open my $fh, '<', $name or die $!;
            binmode($fh);
            return $fh;
        }

        die "Bootstrapping failed: cannot find $module!\n";
    }, @INC);

    # Now load all bundled files {{{

    # initialize shared object processing
    require XSLoader;
    require PAR::Heavy;
    require Carp::Heavy;
    require Exporter::Heavy;
    PAR::Heavy::_init_dynaloader();

    # now let's try getting helper modules from within
    require IO::File;

    # load rest of the group in
    while (my $filename = (sort keys %require_list)[0]) {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        unless ($INC{$filename} or $filename =~ /BSDPAN/) {
            # require modules, do other executable files
            if ($filename =~ /\.pmc?$/i) {
                require $filename;
            }
            else {
                # Skip ActiveState's sitecustomize.pl file:
                do $filename unless $filename =~ /sitecustomize\.pl$/;
            }
        }
        delete $require_list{$filename};
    }

    # }}}

    last unless $buf eq "PK\003\004";
    $start_pos = (tell _FH) - 4;
}
# }}}

# Argument processing {{{
my @par_args;
my ($out, $bundle, $logfh, $cache_name);

delete $ENV{PAR_APP_REUSE}; # sanitize (REUSE may be a security problem)

$quiet = 0 unless $ENV{PAR_DEBUG};
# Don't swallow arguments for compiled executables without --par-options
if (!$start_pos or ($ARGV[0] eq '--par-options' && shift)) {
    my %dist_cmd = qw(
        p   blib_to_par
        i   install_par
        u   uninstall_par
        s   sign_par
        v   verify_par
    );

    # if the app is invoked as "appname --par-options --reuse PROGRAM @PROG_ARGV",
    # use the app to run the given perl code instead of anything from the
    # app itself (but still set up the normal app environment and @INC)
    if (@ARGV and $ARGV[0] eq '--reuse') {
        shift @ARGV;
        $ENV{PAR_APP_REUSE} = shift @ARGV;
    }
    else { # normal parl behaviour

        my @add_to_inc;
        while (@ARGV) {
            $ARGV[0] =~ /^-([AIMOBLbqpiusTv])(.*)/ or last;

            if ($1 eq 'I') {
                push @add_to_inc, $2;
            }
            elsif ($1 eq 'M') {
                eval "use $2";
            }
            elsif ($1 eq 'A') {
                unshift @par_args, $2;
            }
            elsif ($1 eq 'O') {
                $out = $2;
            }
            elsif ($1 eq 'b') {
                $bundle = 'site';
            }
            elsif ($1 eq 'B') {
                $bundle = 'all';
            }
            elsif ($1 eq 'q') {
                $quiet = 1;
            }
            elsif ($1 eq 'L') {
                open $logfh, ">>", $2 or die "XXX: Cannot open log: $!";
            }
            elsif ($1 eq 'T') {
                $cache_name = $2;
            }

            shift(@ARGV);

            if (my $cmd = $dist_cmd{$1}) {
                delete $ENV{'PAR_TEMP'};
                init_inc();
                require PAR::Dist;
                &{"PAR::Dist::$cmd"}() unless @ARGV;
                &{"PAR::Dist::$cmd"}($_) for @ARGV;
                exit;
            }
        }

        unshift @INC, @add_to_inc;
    }
}

# XXX -- add --par-debug support!

# }}}

# Output mode (-O) handling {{{
if ($out) {
    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require IO::File;
        require Archive::Zip;
    }

    my $par = shift(@ARGV);
    my $zip;


    if (defined $par) {
        open my $fh, '<', $par or die "Cannot find '$par': $!";
        binmode($fh);
        bless($fh, 'IO::File');

        $zip = Archive::Zip->new;
        ( $zip->readFromFileHandle($fh, $par) == Archive::Zip::AZ_OK() )
            or die "Read '$par' error: $!";
    }


    my %env = do {
        if ($zip and my $meta = $zip->contents('META.yml')) {
            $meta =~ s/.*^par:$//ms;
            $meta =~ s/^\S.*//ms;
            $meta =~ /^  ([^:]+): (.+)$/mg;
        }
    };

    # Open input and output files {{{
    local $/ = \4;

    if (defined $par) {
        open PAR, '<', $par or die "$!: $par";
        binmode(PAR);
        die "$par is not a PAR file" unless <PAR> eq "PK\003\004";
    }

    CreatePath($out) ;
    
    my $fh = IO::File->new(
        $out,
        IO::File::O_CREAT() | IO::File::O_WRONLY() | IO::File::O_TRUNC(),
        0777,
    ) or die $!;
    binmode($fh);

    $/ = (defined $data_pos) ? \$data_pos : undef;
    seek _FH, 0, 0;
    my $loader = scalar <_FH>;
    if (!$ENV{PAR_VERBATIM} and $loader =~ /^(?:#!|\@rem)/) {
        require PAR::Filter::PodStrip;
        PAR::Filter::PodStrip->new->apply(\$loader, $0)
    }
    foreach my $key (sort keys %env) {
        my $val = $env{$key} or next;
        $val = eval $val if $val =~ /^['"]/;
        my $magic = "__ENV_PAR_" . uc($key) . "__";
        my $set = "PAR_" . uc($key) . "=$val";
        $loader =~ s{$magic( +)}{
            $magic . $set . (' ' x (length($1) - length($set)))
        }eg;
    }
    $fh->print($loader);
    $/ = undef;
    # }}}

    # Write bundled modules {{{
    if ($bundle) {
        require PAR::Heavy;
        PAR::Heavy::_init_dynaloader();
        init_inc();

        require_modules();

        my @inc = sort {
            length($b) <=> length($a)
        } grep {
            !/BSDPAN/
        } grep {
            ($bundle ne 'site') or
            ($_ ne $Config::Config{archlibexp} and
             $_ ne $Config::Config{privlibexp});
        } @INC;

        # File exists test added to fix RT #41790:
        # Funny, non-existing entry in _<....auto/Compress/Raw/Zlib/autosplit.ix.
        # This is a band-aid fix with no deeper grasp of the issue.
        # Somebody please go through the pain of understanding what's happening,
        # I failed. -- Steffen
        my %files;
        /^_<(.+)$/ and -e $1 and $files{$1}++ for keys %::;
        $files{$_}++ for values %INC;

        my $lib_ext = $Config::Config{lib_ext};
        my %written;

        foreach (sort keys %files) {
            my ($name, $file);

            foreach my $dir (@inc) {
                if ($name = $PAR::Heavy::FullCache{$_}) {
                    $file = $_;
                    last;
                }
                elsif (/^(\Q$dir\E\/(.*[^Cc]))\Z/i) {
                    ($file, $name) = ($1, $2);
                    last;
                }
                elsif (m!^/loader/[^/]+/(.*[^Cc])\Z!) {
                    if (my $ref = $PAR::Heavy::ModuleCache{$1}) {
                        ($file, $name) = ($ref, $1);
                        last;
                    }
                    elsif (-f "$dir/$1") {
                        ($file, $name) = ("$dir/$1", $1);
                        last;
                    }
                }
            }

            next unless defined $name and not $written{$name}++;
            next if !ref($file) and $file =~ /\.\Q$lib_ext\E$/;
            outs( join "",
                qq(Packing "), ref $file ? $file->{name} : $file,
                qq("...)
            );

            my $content;
            if (ref($file)) {
                $content = $file->{buf};
            }
            else {
                open FILE, '<', $file or die "Can't open $file: $!";
                binmode(FILE);
                $content = <FILE>;
                close FILE;

                PAR::Filter::PodStrip->new->apply(\$content, $file)
                    if !$ENV{PAR_VERBATIM} and $name =~ /\.(?:pm|ix|al)$/i;

                PAR::Filter::PatchContent->new->apply(\$content, $file, $name);
            }

            outs(qq(Written as "$name"));
            $fh->print("FILE");
            $fh->print(pack('N', length($name) + 9));
            $fh->print(sprintf(
                "%08x/%s", Archive::Zip::computeCRC32($content), $name
            ));
            $fh->print(pack('N', length($content)));
            $fh->print($content);
        }
    }
    # }}}

    # Now write out the PAR and magic strings {{{
    $zip->writeToFileHandle($fh) if $zip;

    $cache_name = substr $cache_name, 0, 40;
    if (!$cache_name and my $mtime = (stat($out))[9]) {
        my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
            || eval { require Digest::SHA1; Digest::SHA1->new }
            || eval { require Digest::MD5; Digest::MD5->new };

        # Workaround for bug in Digest::SHA 5.38 and 5.39
        my $sha_version = eval { $Digest::SHA::VERSION } || 0;
        if ($sha_version eq '5.38' or $sha_version eq '5.39') {
            $ctx->addfile($out, "b") if ($ctx);
        }
        else {
            if ($ctx and open(my $fh, "<$out")) {
                binmode($fh);
                $ctx->addfile($fh);
                close($fh);
            }
        }

        $cache_name = $ctx ? $ctx->hexdigest : $mtime;
    }
    $cache_name .= "\0" x (41 - length $cache_name);
    $cache_name .= "CACHE";
    $fh->print($cache_name);
    $fh->print(pack('N', $fh->tell - length($loader)));
    $fh->print("\nPAR.pm\n");
    $fh->close;
    chmod 0755, $out;
    # }}}

    exit;
}
# }}}

# Prepare $progname into PAR file cache {{{
{
    last unless defined $start_pos;

    _fix_progname();

    # Now load the PAR file and put it into PAR::LibCache {{{
    require PAR;
    PAR::Heavy::_init_dynaloader();


    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require File::Find;
        require Archive::Zip;
    }
    my $zip = Archive::Zip->new;
    my $fh = IO::File->new;
    $fh->fdopen(fileno(_FH), 'r') or die "$!: $@";
    $zip->readFromFileHandle($fh, $progname) == Archive::Zip::AZ_OK() or die "$!: $@";

    push @PAR::LibCache, $zip;
    $PAR::LibCache{$progname} = $zip;

    $quiet = !$ENV{PAR_DEBUG};
    outs(qq(\$ENV{PAR_TEMP} = "$ENV{PAR_TEMP}"));

    if (defined $ENV{PAR_TEMP}) { # should be set at this point!
        foreach my $member ( $zip->members ) {
            next if $member->isDirectory;
            my $member_name = $member->fileName;
            next unless $member_name =~ m{
                ^
                /?shlib/
                (?:$Config::Config{version}/)?
                (?:$Config::Config{archname}/)?
                ([^/]+)
                $
            }x;
            my $extract_name = $1;
            my $dest_name = File::Spec->catfile($ENV{PAR_TEMP}, $extract_name);
            if (-f $dest_name && -s _ == $member->uncompressedSize()) {
                outs(qq(Skipping "$member_name" since it already exists at "$dest_name"));
            } else {
                outs(qq(Extracting "$member_name" to "$dest_name"));
                $member->extractToFileNamed($dest_name);
                chmod(0555, $dest_name) if $^O eq "hpux";
            }
        }
    }
    # }}}
}
# }}}

# If there's no main.pl to run, show usage {{{
unless ($PAR::LibCache{$progname}) {
    die << "." unless @ARGV;
Usage: $0 [ -Alib.par ] [ -Idir ] [ -Mmodule ] [ src.par ] [ program.pl ]
       $0 [ -B|-b ] [-Ooutfile] src.par
.
    $ENV{PAR_PROGNAME} = $progname = $0 = shift(@ARGV);
}
# }}}

sub CreatePath {
    my ($name) = @_;
    
    require File::Basename;
    my ($basename, $path, $ext) = File::Basename::fileparse($name, ('\..*'));
    
    require File::Path;
    
    File::Path::mkpath($path) unless(-e $path); # mkpath dies with error
}

sub require_modules {
    #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';

    require lib;
    require DynaLoader;
    require integer;
    require strict;
    require warnings;
    require vars;
    require Carp;
    require Carp::Heavy;
    require Errno;
    require Exporter::Heavy;
    require Exporter;
    require Fcntl;
    require File::Temp;
    require File::Spec;
    require XSLoader;
    require Config;
    require IO::Handle;
    require IO::File;
    require Compress::Zlib;
    require Archive::Zip;
    require PAR;
    require PAR::Heavy;
    require PAR::Dist;
    require PAR::Filter::PodStrip;
    require PAR::Filter::PatchContent;
    require attributes;
    eval { require Cwd };
    eval { require Win32 };
    eval { require Scalar::Util };
    eval { require Archive::Unzip::Burst };
    eval { require Tie::Hash::NamedCapture };
    eval { require PerlIO; require PerlIO::scalar };
}

# The C version of this code appears in myldr/mktmpdir.c
# This code also lives in PAR::SetupTemp as set_par_temp_env!
sub _set_par_temp {
    if (defined $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/) {
        $par_temp = $1;
        return;
    }

    foreach my $path (
        (map $ENV{$_}, qw( PAR_TMPDIR TMPDIR TEMPDIR TEMP TMP )),
        qw( C:\\TEMP /tmp . )
    ) {
        next unless defined $path and -d $path and -w $path;
        my $username;
        my $pwuid;
        # does not work everywhere:
        eval {($pwuid) = getpwuid($>) if defined $>;};

        if ( defined(&Win32::LoginName) ) {
            $username = &Win32::LoginName;
        }
        elsif (defined $pwuid) {
            $username = $pwuid;
        }
        else {
            $username = $ENV{USERNAME} || $ENV{USER} || 'SYSTEM';
        }
        $username =~ s/\W/_/g;

        my $stmpdir = "$path$Config{_delim}par-$username";
        mkdir $stmpdir, 0755;
        if (!$ENV{PAR_CLEAN} and my $mtime = (stat($progname))[9]) {
            open (my $fh, "<". $progname);
            seek $fh, -18, 2;
            sysread $fh, my $buf, 6;
            if ($buf eq "\0CACHE") {
                seek $fh, -58, 2;
                sysread $fh, $buf, 41;
                $buf =~ s/\0//g;
                $stmpdir .= "$Config{_delim}cache-" . $buf;
            }
            else {
                my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
                    || eval { require Digest::SHA1; Digest::SHA1->new }
                    || eval { require Digest::MD5; Digest::MD5->new };

                # Workaround for bug in Digest::SHA 5.38 and 5.39
                my $sha_version = eval { $Digest::SHA::VERSION } || 0;
                if ($sha_version eq '5.38' or $sha_version eq '5.39') {
                    $ctx->addfile($progname, "b") if ($ctx);
                }
                else {
                    if ($ctx and open(my $fh, "<$progname")) {
                        binmode($fh);
                        $ctx->addfile($fh);
                        close($fh);
                    }
                }

                $stmpdir .= "$Config{_delim}cache-" . ( $ctx ? $ctx->hexdigest : $mtime );
            }
            close($fh);
        }
        else {
            $ENV{PAR_CLEAN} = 1;
            $stmpdir .= "$Config{_delim}temp-$$";
        }

        $ENV{PAR_TEMP} = $stmpdir;
        mkdir $stmpdir, 0755;
        last;
    }

    $par_temp = $1 if $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/;
}

sub _tempfile {
    my ($ext, $crc) = @_;
    my ($fh, $filename);

    $filename = "$par_temp/$crc$ext";

    if ($ENV{PAR_CLEAN}) {
        unlink $filename if -e $filename;
        push @tmpfile, $filename;
    }
    else {
        return (undef, $filename) if (-r $filename);
    }

    open $fh, '>', $filename or die $!;
    binmode($fh);
    return($fh, $filename);
}

# same code lives in PAR::SetupProgname::set_progname
sub _set_progname {
    if (defined $ENV{PAR_PROGNAME} and $ENV{PAR_PROGNAME} =~ /(.+)/) {
        $progname = $1;
    }

    $progname ||= $0;

    if ($ENV{PAR_TEMP} and index($progname, $ENV{PAR_TEMP}) >= 0) {
        $progname = substr($progname, rindex($progname, $Config{_delim}) + 1);
    }

    if (!$ENV{PAR_PROGNAME} or index($progname, $Config{_delim}) >= 0) {
        if (open my $fh, '<', $progname) {
            return if -s $fh;
        }
        if (-s "$progname$Config{_exe}") {
            $progname .= $Config{_exe};
            return;
        }
    }

    foreach my $dir (split /\Q$Config{path_sep}\E/, $ENV{PATH}) {
        next if exists $ENV{PAR_TEMP} and $dir eq $ENV{PAR_TEMP};
        $dir =~ s/\Q$Config{_delim}\E$//;
        (($progname = "$dir$Config{_delim}$progname$Config{_exe}"), last)
            if -s "$dir$Config{_delim}$progname$Config{_exe}";
        (($progname = "$dir$Config{_delim}$progname"), last)
            if -s "$dir$Config{_delim}$progname";
    }
}

sub _fix_progname {
    $0 = $progname ||= $ENV{PAR_PROGNAME};
    if (index($progname, $Config{_delim}) < 0) {
        $progname = ".$Config{_delim}$progname";
    }

    # XXX - hack to make PWD work
    my $pwd = (defined &Cwd::getcwd) ? Cwd::getcwd()
                : ((defined &Win32::GetCwd) ? Win32::GetCwd() : `pwd`);
    chomp($pwd);
    $progname =~ s/^(?=\.\.?\Q$Config{_delim}\E)/$pwd$Config{_delim}/;

    $ENV{PAR_PROGNAME} = $progname;
}

sub _par_init_env {
    if ( $ENV{PAR_INITIALIZED}++ == 1 ) {
        return;
    } else {
        $ENV{PAR_INITIALIZED} = 2;
    }

    for (qw( SPAWNED TEMP CLEAN DEBUG CACHE PROGNAME ARGC ARGV_0 ) ) {
        delete $ENV{'PAR_'.$_};
    }
    for (qw/ TMPDIR TEMP CLEAN DEBUG /) {
        $ENV{'PAR_'.$_} = $ENV{'PAR_GLOBAL_'.$_} if exists $ENV{'PAR_GLOBAL_'.$_};
    }

    my $par_clean = "__ENV_PAR_CLEAN__               ";

    if ($ENV{PAR_TEMP}) {
        delete $ENV{PAR_CLEAN};
    }
    elsif (!exists $ENV{PAR_GLOBAL_CLEAN}) {
        my $value = substr($par_clean, 12 + length("CLEAN"));
        $ENV{PAR_CLEAN} = $1 if $value =~ /^PAR_CLEAN=(\S+)/;
    }
}

sub outs {
    return if $quiet;
    if ($logfh) {
        print $logfh "@_\n";
    }
    else {
        print "@_\n";
    }
}

sub init_inc {
    require Config;
    push @INC, grep defined, map $Config::Config{$_}, qw(
        archlibexp privlibexp sitearchexp sitelibexp
        vendorarchexp vendorlibexp
    );
}

########################################################################
# The main package for script execution

package main;

require PAR;
unshift @INC, \&PAR::find_par;
PAR->import(@par_args);

die qq(par.pl: Can't open perl script "$progname": No such file or directory\n)
    unless -e $progname;

do $progname;
CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
die $@ if $@;

};

$::__ERROR = $@ if $@;
}

CORE::exit($1) if ($::__ERROR =~/^_TK_EXIT_\((\d+)\)/);
die $::__ERROR if $::__ERROR;

1;

#line 1011

__END__
PK     �{?               lib/PK     �{?               script/PK    �{?���[�  �     MANIFEST�Vmo�0��_�vZ�Uĝ�O"e@�I�VM�R�r��xu��vxѴ�>���$�O�����wg!���f�  )�� �~њP-���v�FJ�)v�ᷫ��!����)�$Q�|.AH�lZ'[ʉ��lc�F}l�)TE1��ا	QZ���+����{� �GwT
�nD�: ����dN�i9ኋ�TlpC�'2l��aR�'
�-S(�w�-�0k�������<�M�p����UB��1t�d�d�E����W�7P]�۰b��2���{.�|Ο�{-��.��k�;�|-�b����;��ԍ}�{T�Ȯ�U�J����wv���4(��c�f
�;�hUЄ�tDgF�� J) R�ϙn�+Z�Ě� )w�@H�`��wU؃Y)|w(��4�N`M�r�.co�+i=H!	��yPX��@�T�Y���
�g��-��E�7�&���qY������&��$S�������[-B��j���&��j�;���ݍ� �� ߋ� �s_V�*���X�S}��uXw�	��c/"�����$d<�4>�~��;dF*f���p�x�8	;gz�Ѩ� ���c�A��W�+�u���F;g>tj&��"�?g\��o�ZB2��7�D;Q-A��jG�Z�/߷�4TQ�Z�,�7�̌Y��N��{[���:���~,~�W���=��p��|�d�LU�x�б1j�E��6�.r�Em�h+��X��%YwάPK    �{?�I[�   �      META.yml-�M�@����;v\Ύ�����(8?b��E\����}�yp��E���g��L����pwm\�
�[Sn���ī��oz�a0î��x�P���&\�[(ڦ��E?Q�'��s�˪��~&��d�d}�Q� ?�!DSzT��1�r��^u1_PK    �{?l�7�-	  �)     lib/Algorithm/Combinatorics.pm�Zis۸��_�����^ɝ�t�:�L��ٶ9&ɶۑ5��,�(��aY����y E��;��#�}Ԏ/�����?S�L��^��T<����v+�	V��F��V+����`��`px���[	�T�ο^��˻�����P~��O�=��o�������x��b���+���G��$~M���W�H̒u(zf��e�����Ӕ��n��HΓ׿������Z7�/Uo,8+�D"��p�#i�����I�"��6B�"Z��-����:;0#��RI!0�&b4��a�t �2�}����˟?�"]����ۆ�p���Ϛ�rͺ�'n[�@��9���΅�p  _���~$�4
L��LR��������;.��zL΀���G�#��5����],�`'Z�^&�6B��~O2�|[0��HpzH�<��:�05c���ط���_�rs������a����f0��v�e�h� �a�E V]�J�C
�rS�4g�ϴ72�������36"w֛W�|�&���-�78Rk���ة��7K�z�_́uS=	���Y%����lX�g�M�R�b��sah,�x��"��5�S&��!������JA��/�Q7V�̓�9W��*"�"C"}RP)4�pf5s�ݜU6�o$՞X�ީt�n��-U$��ͤ+ч�T�����E�Vq�G5/�_�u� �٦����ա@_�&v�_�AN�4E�	�4S��Y��/���e�S-����fԂn�����'���7� _��z���y�<]sz};���E|���V"�4���L�i�J�v���\����/��d��a���H���dd�_5�J�t��QX[�*Y�-թ��\�>θl7�z�}���Ge�i..�h�,X�[��5�)MG�/n��Sw�-)�Ҥ��!����ѯç��A����*�݆`��Ug.x�x�ŷ�ԉ[��lw�Em�`�]���4�*�Y�&,Ql�B���2j�T%Wz�KyV��է�������=S�+����k1�m�J��V�|w�q0I8{�	iT.�iy�f*�����y�aW�VN���a���?�P�?���~O��!����#�獗�zT��)ˋӛ@:��7���%G�:�:aeD��1���<"5n~4�Ϧeak��(jX����Ͷ��+���q����f3�'�<�p�m��-@o~;�߂��d RBF�\���8�ڝ��0��Q4��}�|_���]l���Ac�pk��������+|سgD�%��*��'qoDa}N�6Z{�6�sޔ#�j��sF��2�O4AE����f�0�on�Йg�9+Y�[�a�ޜ��q�8OlP�ӆ)o���D��,�� :���1�Wr;�8��aq�](��]�m-����L�Ǭ��Z�+/� �;����hǾ���S�w��#'X�sY���^G�al����U�����'���3p�D���o��A��92v`>'穌�WN�W�B�(���n���c�����v�3���/��]�H'��h+�E{�Tһ|Ȟ��g�|@j|�q�j��4�`�>��O�����B�wdTzE|V59[D ������w�ޕ�ߑ�v�� ���j'���š
���_�=JR���k�<���p}�&���-!Cb�C�մ>�
	S]�Ff��4����2��\{JE��	Ⴌ/�$J��bs��4M`�8E���Z�P/��r�<s+��ݼ��s9K�\[aiŃD��0W�l��_Yɳ�hc�z�Yͥ/X�X��ZKA��2��)��C��UZW��̦t	�1�[����|�^(�6p���b��6��&X��NL��T\	δ���<3CK�1�NC@�tU�Ōgy]_�Wݞ��tO���@�����/��$��	��{4�JO%k6]#V�����t}|!�R)1�2�r�c}?#�s�EB�U57)��vg������j[1_S��悮~̀�\q#К�5p�*��F��1�j�Tw��l��P%8�B&M"{*�T�qF�$r)�֎6 �(?5-Y�X�jI��l&#Ԏ\2P��+1Y{�� l�R��7��!Q(N�D"���TG�L�3cx��=m������(��nTy���S�:/"�&Z�za6E�#�Gr�O~��SnJP���ϕ�wdr�g7sM���O�	���e�E����c�q�	�!v[�*J[�7��e�vkE��h�IN��84
�ӆ���zƝv��:����Dg����(�N�*�nV:��q^�����B�}����V�PK    �{?�ik�  E     lib/Excel/Writer/XLSX.pm�SQO�0~߯�	���0����4��$��R��v�]����N|�����}����[[��1�$o����`y�X�UyT��l�����c�O����+����[�߅�t@�0��,��(��A�t�lÞ��]����0���0��ܪ��{>g%Ӭ/%�>���P鍧^+^�(-�BI`�C�&��4%<��(�b:6���X-�m��Rȍi��R�������Q�t�R*����0�Y\�[�;=����N<���<.n�D�D�pԡ#��9���.E�^�>��ݸ|�6/�1t�u�/,2���~���`��@y*y�E�;�׹��EE���
	D��_h���>it{�[�֘�+X7���F[k�/}��b7���n��錢�/PK    �{?{�]�V)  �    lib/Excel/Writer/XLSX/Chart.pm�=kw����+�	�FJ��T�\�~���y;i{o��,I��h���.-1���/f�] \�"e7QNi1��0|��9g��Ӌ���Q�5/�����?��&e�7�޾5KFgɄ3�9:"��#�::B���n}|�?��?q�]�������IQ�s�z�O����n���4g�"�y�����yZ��(ߣ�٢L'�5;���������?�iξ}�L�2�a?OG9��p4K򽢜`�'�h>�y�`3ɉ�����>D� ��2���H�O��?ˊs���A���N���!۝��}��Yr�ּ���^�@PԿ�Uu��j��<)s����'�~�γ��&u�{[��7�ϱ$�c�fi�`��o]d��bP�"�Ř�F��W(�o��!G�$�p	�ĨN�Y¶��=���G~����T��P��ߟ�x���u{���{=�s-�y���\lm�_��/6��i1F9-y=ǁb#��b�3�& �Bb�@���z1� ��|�0���n�vg4/K!i}�N�1��Z�����]:��eU�l�,�oڜ�y����?:���8��$c�K��<-�Bw[~�~���w{�[.xQ�Y�e�
��Oӊ�<)�)�GQ�����(���������&�c�=�5��YQ֤,���,=awJ�h���r~��@(/�$B���~�̳����s�!ѕ]���t�J�d��>W<;9�8y���J`���I��%3?NK��z����E���Y��R��6d!p�ݰ ��u�O�|<��K��*;h��k6X/2����Pr�V�r�ZT�&�`��|"&�e�*9/l�6P�'<fE�*�	��\5�h�<,@�M01'=`YLjd�����e j���e�b���]��A@�:	t� ��E�G��&�f\L�ݑ�©.D��i�&a�k!b � ��? �o�`*���lp�f\*�G�;K�1z8�1A@��߮o�����ݚ�;�I����|���y�K�������&lt�j���9�?hσLjd ���œ	 ��Uq���"@���@C�}�4�y�����Vq2 H0Bnm��ji�����YQQ#��~�vfu2�s瓔��B���L�X�������zҡA�I<����PS�]8��w�z6|�}0����hv���t$]5Z:\s+����Ji��,a�	�!�{3����O�@���_?I�	(؇#�|t&� �Q��J�v�9�Y5��$�c!�[�#.���~��o����u�D(M>*����f.�RB�`=�)�M��6yy����O?u��%i'p�t��ai/Ԑ�xV�o�p���'l&��xpdԺw���0�km�* ���ն��V���fU�R�YG��l Z��^�a7���0_�����;�?��cǒՊ"!�#a�peXIz����~i���9����p.:;��G	������ ��ؼ��s p��[6w�Z�M�ݱ�nKюPk�ڨ��W���I�>NSww,���E"l8�pn���v��5�j7�64��Y�c^��PB�y�/��X*��&�����S� �p��֍��� ar'fw�tmGC~C�u�¹§v�����iR�	١)	�6F���w_�u)Ll��6�n��{�e]��dȳ���dc,�c�M�{*tdN�=�=�q}�	[C*@�{�`y�'����T$�Q;f[Z���}�g��p��G=(Ԕ�*�-תP��܀mb�v��J�$����x�M.|��q����*�Rk��adLB�6$�� Ԉ���){���; ��+�����h��5�����[�^��g�`��2Ww��oB�%+�����~"	r厕�{�4-�n~hIB����%^V�HU�W4�D�[�����Ƣ�h,V�EW�Xܤh�i�ww! k�~����2� ���A�^�X�`�Fm��&`{������(��n>��6�e�1�8�I�*�_���YV�b��t�����)N�O��l�S8��a"��h���
�`j��3���$Rtl8���l�њ�7i���Z���p��r	o���2n��c���d��j5�N��Q1��lZ��gtż��Z���ΥB7���oQ�|�/.��V�i8���lRs1�ҼuQ��&���}SN�����HGZ�)D�'nc��i���I�wT��pA�� ������ �S�����i�L�q����X�`�"���#`U�A.͒V�Q6I�����Fmy��oOp�X�l{�]8�`�= �v軏~*���Q� �^E�:�*�����͌��~�M�14O�QK�u!JG�L�~����	�p&�Kn�4�{c���O�\���:�:ߩ �7��:\�C��4uhh�H��!��~7F]�Q�>5,1pk�(v��G��4���8�̩�(�/���($�<nP�[��6���]���� oj���ȸ���J���<���4��dJ�F��~��Pi��M,�m煾.�j����T	l �w�ğX����և@��.��:�;6���p��: RQ �9�]�� �v	�p�dΜ�!�<f��n��VЯ���~��s�
ؖQ�2�A�D����6�j��8WAl.��G{n`����B��$e�,�����a���,�LL�����%nPP��\j}^�
V�b����T�����bݝ[�%��!��������x�J�qgc辅�YQ�U°�q3D;0�` ��e�t�g���O?����M��u�ӿ>z��G���:�A��լ��� �KgtC��km���E궁0k�d
1�,��w�xP*��*Fia�x�$��P�]�R����=��+�R
��DZ��$w{y��"���	����� �R�`���J7�|.�+%�d>�R=�QW@�E`=3�-���E풆��՞�۳�lX6ڏ�������g��������W���{5�~5�����?o����&�W�϶��|g���9G�<�� �E�u�`�|�ۄd�cŜNr���'B+������[M��pZ��'�j��|�An�}�X5X
*��1&�G�`��=5��!Հ�-�B��$E�9�8��d�PDu�R�>�.�|��Y1D��3}��-��\#at�	Ŕ��蝉y��)��8�)�9�0�!׍��pAV	��T���+sYf�o�����s:m�7��xK�;��W�65'�`��0���KfU����j9$&�B��	n��{tC���Y���a�����Gkɔ.�x��a�v����J֫8�V1��|�k~J �����oE3�ܴ����5y�A�U���!�7�+��F���q�g�]@�iE�4@wlŋȗ�}L#O�
�˳��}y��a�'��8�� X�7ӧ��߷[�1nO���%8	Ms4TZ�{����'A���^P���PgKE���\����o"�n��7F�^pM�t�'C�=g����(훊���z����o�˕��/^|��_���y�	LQ�,��?�w���<�}����M7PC
����~�~�GƱ��ؐ����E[�y�Ucn��<W�R\)�dtf�φ�n���������Y^��nB��{d��>4.Fi�	�l�ݶ�W�%@�2��*�����Y��溿��5K�۪+�h�9��@�F9�gKΰP��/����UG��U�tf��e�4���5?B��A��&�N�.n��N�)�s�9���a';M=�HTN }2�B��?Ý<��%�)��=f���{���p%�L[c����c�� %)@��_k�$���O'��'���o� �5K���L���t4�7�
x���7y���,y5+�q�"�Ax�y���r��N#�(� ��3)������n�7>�_*'"�Ϝ���	�=h�M�a���~�*<4�w[����{�»���Vᗦ��V���V�W��WY:�Y�V?{c�/��vaQ��F?�殆p��	��\�Zh�95˳݉�A{�~��|�Χ���P/��{]�0a���UΫ���$|��#��	��}դ�z�����O~y$�y��Õw���Zf�:���>��ޚ�Bv��ڝ�;��ܘ �IZҕ�F#�\,���^�)��V#��t�{�F�r+��[s4� �	���Y���+�B��9NK�z�P}Iƾ�I�S��)�`鞠�c乒��Y0��R����%��q�WT������6R��%�Q�p��P���e��܅T���$P�h!�m�F��m:+�ɠ� �I�eh�5�� +�X�A���eҢ���%�bғ0Vp��vcǘ�[GhG�h�I
L=���o��ܷv�U{�;����[��e{��j�����͕>�4����7�a��Өzz�~T �ۂ:Q�D��uI�֎^��V�Լ-�J�;�+k�F[˵��ݹ�V�:*�~_�b_+��wD#Ln�G]�ͭ�<�J���vk$+	�X*���M�"j���m�A����M�n��i��4�
�M��?-��L�|�q	��� .����:��J��π�����w�jhZF�c�,��)��(3,�?��Y6�nf��O�4%�Q��g@���,�*8��m^~���S+���-���_lAiksݘ�l���ͅT�V[[�v:�v%+!����-��,�{o�4��W�`'Ш����"iJ ��4�� �U���+�α�ƍR�w����N�˵Zo*�����X���Z����,��� bl4X������y�&x4��d�V�A�t�X�'G�N�Ɉ0���oR����p�O���`�"�d*i!u+>9�t[�O�ڰ����V�ʧ����l��KZ�"�mW��h��*�V���ƾ�޳�����vu��Ų�4YM�m7ՠ]�Մ@LZ�y��,�%���V>�շZ��u�lQ�U��O�f�X��*�ח�p<V)4�f2>H�s��1+[�]+�H���C¡c�9�@b�`vD���yi,�Eȱ>����������]�X0-���CiL�&v4�Ơ��!�'�C$>���P2O2?�9����H���$��瞝�0
Z]p̲��ݸM&�/�>���ѩB�7�=���~LO| &�3f����\�&���r�3m�{M �����	d���;�:U�w�}�&y�u�Z}U��,ك/����>��|d��ő=���m�F��ك/���W}������Ȯͬ��P"��NMХO̜��Rp�4|
�G?�Z誡L�l�Q����+�Ę& �x{�dy�W�}f�����[>E�S��i�lp�\����Q~�#*k0ė}@ywi~{2Yc����';o���YN��N����O��rZ׳��}�R�	%��f�W�{$�=SO��������c�q����i��������$�:�$�[UJ�Jqr���z��<CE'�7�zƗ~(�G��uc륇��F!�z��,N��U\�ť���?����;�k	k�E�R��e���
ӧ/]�S H<���ex0�rO���0�Og�B1H�4����� �,��W��37V�wT�	}R@8'��Ot"y��ؾ���p��I�d�r�o�F�EW�86����)�J2��z4��k筷��D{�};.|�o�!�5��,t��f;U��0�3�m7v=��S��em���T�hn�9����#H{y@�(a���J]{�A��� ��=��˳�R*�K9(`����C���Š��+�d^W~7�W�D_h�\�����A��F�$��_��˪^bFI��"�A>s����nr��n������P��8|��H�H�t��FG=D�#�i�)�ҽ�2K�\^ȃR�SX��,Zo�!��,�;o�,4����g�u�p����q�s&�ʡ��N�^ܒ�K����� Fm���V��upYo˟|<b�����g;Q�˨��^���l�Ưy��*�����r�;/�cE��E��9��}�S�5k�إ���Ȟw����{�b��j/�W&��)�b�+89��Q:�ZDQl_�� �,SE"�>��-.,Fv˞b���QZ��`V.C�u>i<����6���a}�k<�����z���D2D�j ��=������Z�B0 q?��!�k)	^��i�Ll�94�a�ܤ��o���|��	B�"5q��� �qSHw|R{?���)-��f%*���ud�F�������1!5���$��.i��Yٸ?k^�$�ݧ$���t�y�Lw$M���i57o��W� �����B8���K�<���*��4$���]:s�zRO�~ES�>�k�!���%�~��(3^ɤ;������4�B��y�䆛
��Mn�`T֩������ĵ�7�.%?��<�YWv$9�i�Ȧ�z��[�vגM�%�����sh"�%���,�X\2��g��DB���eN�ټ�9�[w�����"�#����ˊkJ��b+.V���z�$��#��x*V�E�xB��%��fDy��cMG"W���S�01��.L�� �k=q-C�)�"�)+�O�I�.�kN��Y��9�K�S�jB*e�Zr�
\J�#WO �|��gmֺ��Oac8��P��&�
����>�K���QpJU�x�M=즋 ?�	ʔ�̃p��X��*���|��,��z��xr�@/|Ћ&t�uߣ�^s�W8q�m+��feL�Ȗ��Щ��Et/X��֎�!Z��Ǩ4_X�z�J���%6�U�aW	Wi7�a�0�Ϧѽm0�'S8��NGgχْ�(ڽ�Q�A����0*��Z�  �b�^!�<J�٢+���� �P\Q����$�#�2H�'�% ӹ\!�w''��})��m�~���E־O������U��7�b�U��i���[�� U�I��y��Μ�T]����X�'bP�P�mQMxmK:�c���r0)S<���M�4�0F��1�W�`���d�p`�f��}%�%W6Q�,���zx���$A�"/j��\�=l>+}u{�x7{�X�=��/��n@�>4����6"�_x}�֗�;$�nq�F]���=� ������� !d����&�K;�e��F�0:��C2:׷{G���E����̂�����QA���/]�۽,m2V�����,��oNe�7Z����v�yM[W�7�O���R�q�yYk�y�f�����4��RQ��K�.G^F�r�J����r`D�5ؖ!�[��E���i�ޘZ]��5ܸ҈��7*K �M����B]�֗����7i�O(*4���;��8m���BUFO,EŮ/0���DA+���L��JJI�!���^ֻ��]������C>mz����7�IX�X��}��'�Hט3g��Gw�2+�EU����)g��N�s�+�����p;�$�k�Z/Wzg�a������G�y\�[0�V��m�'ϱ#2��ݷe92	�ٴ�4<���($-.��O0�n<J�8p�8� ��
��rORy#��\Y��vn�|��s�L��7��}Y|�c��o4|H��@��ܛ&@��Shݳ���53/
:'����Z����s�Pܨ�	��fbk��Gw;>���L��]��6��h|{����-p�/'|��r���tv۾�i�<��ȵ\�X7���]���#����0��v�K\��?�[9۝ٸ��٠<�K�j��Lu��ٲ�g��9"x8M�p`�Ai�d�[S��܋��6�慗O?���K�q���ŋG�+tV5�-J��$~l�ή4mz��B�]�7^�V]�o��Ox� ��Q%e4�G(��0��~��~W��1��~�hX�u1����+V�<��j/>��,��;�طw����b�*E��۝��`�#�.٪7�i��A��2��a�����MxUJױՔ�����4��FF� �`�� ��\c�ё��n1�Щ���.{���mB�60�������]h:o�~H�2�w	E۠R��t�a���=4���h�>�0�k>1Q�sZBE������ѽ����i�o���皔�4��&�c�E�ƙo�@:}�D�U��R��y�ܝv�!mqʓ1,5�:�Ҋ��� C)W�	�&)'i�E �a\�n�OP�q���^�h��-6�C� y�}��M��u��3��g���K�#z��P{_�3�3�u���Z�Q����������t�cؓȅVZ���=�������^[�k�;IZ�~�
O��^����5ZW��<�����a�w�>���+��{Y[���S ���K*��I���O��ռA�+��0����E0l�:�~Q+a���G\i�W�6@C�)09�W6(��K���z��IO<A������~�EXa��e��*���4 )�G�B|L��z�@�P���$�J�3�S�ª��{B���̏�ժ��G�݆�M4_����`�u,b�56#֫D7�{���L�u���:ٚ��wT^��f�C����~��Er4,Ƌ�1J �3H.���_��DQ\J=~��]�'�Y�BI��_s��fTK ���B�j�h��\x:�v��ŗ�m0x��E�_�<`&P��z��W~�H�܅]�_|D�vY�(m<�����)�����.�>��F�tP[b��+k@w��~�µ?APRZK��U�Rvҋ`I�rOCѹ�Qz��S�EpЂ��{0n��^pl��ɋe��Q �Y�eM��aԢ�F�Dt�����cӡa��Rv�8��&����ԁ�K���;����D�M}
[QY��l(5����ʥ�_���}�q,?��wR�������&?T��n�y����8�W�Z�	Y.���`�?�L��{�ɠ^��،p��%L��ҷx�.)��*��Mȯ'�Z|�U���+ʯ�ZW4
�u�<�}��'&��������nSؤ~p�Mx�F�F��|n�{�J·(�!���A����w���fn��J�N�,�P�g��CM�:u�����-��tXD�#�-�Hnz�Jmr
�[(���v[��+B���G1��Ŏ���q�$��6!��s��H��x?s7&��>h��xE)�ZҢA��"d���Xq����� ��h0���H'�8�%�\'�mn�]H��6x�,�e`�+?Y��eݱ���G*��3�K��c�$�2�>]#���Y���,?:�UekP����#�ä�3]�Lw�-�6�NI�ڄp�	r�d�##�ە�GmT�����s�9L����I.���/k��h)z4�=�{��k�$g��5<��Sk����e��͋b.d�`��<)yU������gO/F<�.�(�),[��ߟ�*���?������}���E�'Y�Q����]�<Uy�ژ�{��-vp�e�/���m=�৥�I3J��F��[��Sƞ
��p��^{"�=�Cך�A^�4����d~�-�F��Nx�C��8�N�m��x��d�l ]�0feU?�K�� U�
u�8���z��j��:�*d�w�1�F6�UKj<����A�a�	�r��?M�1���YQ6Z���}������tUN��������Q��]#��E���ڇ[��l�od�e��w5���N4z�wb%�_�y���rOѹ�[��y�Τ*nO���nX{�Vû\l��5XǝL�{�Ǩc9X�o�Yp-(�;m����U���_$�Y��[mJc�d�|����"/���L���]�6j�j�z����Bzg�Ń�bK���L�O��C�x���pb�	_�\����$F35��A�
�Γr1	�@.��Fk��Ζ!V0���eL�X;�Όِ�!፩�KU���<~6�O�	�ʗ�H|f����c2�9�����glDXo�<&�)i#E�M�;�4�&gpsx�dl�n�F߽>,	^�#-~�L#:6�5��}��RQ�oʢ\E�5|'q�̔�m8C�6tn��;�!}/�����:o����8����ϋ��6�w�����X��=eY�=�����~���?Qpٹ�p"D|K<��+w8���[�G�\,��ø��Y�w�uv�%���x�e�*P�: 4�p����R�t�.!}����w�,;��kV/���A[�t��2Z�z����k>�ԏ��N,���SKUy�R���-����;Qz��)9�#��N�z�5����%uc�-2>��$.�˪7�f�4n|!`X�W]č/����y`c����3�E�+�{��0{ݤR�zt����ԇN{H�������{��	�f��,j>
�+dJÙ���<�����t'����g�0�9�\��j]�d��(��ۼD��!����ߓxL� � K�ߔ���<�b}���.9�@��~"m(���Ѵ[x��N-T���@�H��^mc��E���#�:���%Z��m<��%?ߤHFy�p�(%�7�D3[�L��.�D��F�(	�4e\�}�����ܺ7� 	~��O�}2 ��H��?~�խ�PK    �{?8��d@  (  #   lib/Excel/Writer/XLSX/Chartsheet.pm�Y�n�8}�W�v�%@e$h�@m4�@Q�D�l$R%)'�T��Ë$ے�<����9s���\�$�S8��MF�%�T�����2z='R�9�z��/:��Ȍ��C��A�=�t~��6 ��(!J�TH��u0>=�K��U��%T-�'Ec`"���<�Lp�gz޶)gVdK�fs���xp<>:���b��]���D�>|O#n��G�C!gV����rM�2Eb���o��ȨL4��nf�S�$���FdFK0H'��12}:�	�trE��p|�+��_JKi���H����|ȄD�寖�}���%�_�^�����n�������W��Q�;��"�^��M>IX�ǐI� �����T�E�����g����	��<�B��|b�����Kx���)�9�b��Ǌ&S���Sp���Z���cKb�Z���N�AL�Q�J��E��P�c:m�b�����_!�PE$�!2%I���HHVfWQq��&'���a�ރ^"��%w��N����h�b���!MBS�|�/�s{�M�6�{k�Ty���'�:���y�q�$kA�wO-sL�7�:�c�s�*)��:�@j*ڰ��F�[����i+��ifJr��b�L��8���x���D7Rh�Z��}�*��|X���v%{�Ņ��?�'�!v��{\�?�
�l+�����)���O��{s�pj��L���"���N��ܐ&��z1��|pFy���zЭd��L�9-��\��&����d�Vfu���׹�rL��Ydl쾊�o��l~p��r Y���H�\�zàE�&'�:Nƣ6C[�J�f%s�{��eX�).%0A�[�}������q�3�ou
��9��A�Z�+�M-ƑQ������QN$j��-����� (W�_oc���G$Sy��R���i�XR�A+�ǲ;�@���ƹ
���(|�{B��5ԗ�T_��k���>�nq�ΰL<��p�,s�<�^�dvT����g���*����+L<�I��)?c`&�)��g~��ʘg�0�ʎW~k����X2����,Q��6��n��8�)�v�x������iųј�O�g|_S�\������w<�8a��o��8W|�n��n��a���1ל0D��]���Z	n�e=�-���?2V�0��(�u���Ƅ��6�;�}^ϒֲ�j���s,�����x	����*�6�lɶ�O��iJZpݹ�Y09��}�cا�>��yK4Z�fP�U��� �����v�i2:����M�P�d�)�h�r��H��ýe���F���
r�g�H�rLX��Ҳ6yM'ac	��)��P��)���I͒F!�q!�ķ��%]���Q8U,hH��l�k�,��{R��|M�딄]�ܮ�>�k�o٭��t����Z����Ƶ���? �5����f:�q�K���M��.h�v�^K���j��e�q������1t�;S��#2ش���uo@aoU��嶀�?맚L�H$B��X�ugмw����.�L��B�Kw�g�m���TW�r����KEwn���^>c#�9����)_Sw���1��PK    �{?=GG��  �P      lib/Excel/Writer/XLSX/Drawing.pm�ko�8��]�j'N�M��%H�t��m���]`�0���ʢ��������!�ARr[�W�\ ���pޜR}G	A��w�~g'������8�bx%7���A����� 	5�)���f3x2<������4v4A(�q��eh#(��|��B@
5�w�-���K��H��4��N�m"���#'\���E7K������hzx8F�����+��}X��z�8٧�F�K���$�U�B F���7W� )a1��{Eп�qL%�4�Y�MV������t�&	��`��z�?=MO䯌�(����D��ԯK�R�ͪ�wJ��篯7rD(��:�����{3j9w�D���_/~{���1w8�?z:8;��w��8
NB���s�.޽B+4̤ʿ����hO�["t�8e@~���A�i0 ]��я��OQ��B��qF�(���&gr��WΞ�}����5�NB�8)�h��ȟU��Ꚅ!	���2LYd|�A����$�X�G�k�����CG���1���1���r��K#�⑞*��PR}~QgR9�ʊl��-�����J�!�aR|��=��.d�Mv��	��}���������$��h�F6=�V;�0���n����H��A���?�̦�����K�I��f̧̔�0vϱ�2B�+*��H�ޖ�E�K��`r�_g4^s�"�L���i�z�{��$�?�����h/W�eL3c��B��H��͂-.��U'��މc���k���hor�R ۝�an��	�a�0
��q$D� 	�Ӭr*E`���-k��2]gK��џ����U"d������ �D�;"^ٜ3.�����x���ӵ�9P�lM�ս;X�VC�%����@=��iJ�E|]a�Ary��Y��-�dsA��a�Z���fKB�Ρk�\�:q��dx��p���3�E�d�����1���Y��qa�+ W29˸��J����$��X���a�̣��nQ���ߧċ!�"/at�`t�0�t��wcp ��D/��`pb�  �;i�l�P�k"�DV�n��d�d�g(��Y����^h d�%��l���I{8=EG2�2���m�},@I��rHf<lLH*~Y2���Z�Tij�<Ʒ!&7�mH��m\���� �#�ȳ+q�VH㴲V�A�jk�v��j<,'�UzoN�Q��+b薆!�̕��iB0b�U�Q��3c�ʩ���^bp���7.{�X��VB�r�q�m�Z�*��ʼ������ s��l���>՚�������SAU�~�N9?n�eb���U�X��	ea�``�2��E�;5מ,]n	�Q������ &��$�Y���l��c��)��oB$@F�����Ϗ�������O���H[:W{z'?=;.��������=D���Y�h��٢��ߜ�_�Xh�N,�2���_�d�mIr����`���c�B P>t�U��S(�G�!���E }TbЅ���%�GJ��hQ�JBmi��0;.s�����r�~�����m�+٦e��	B���p�&����3Oa�h4 z���L�ñ���R;.�zd S���X�?Q��[� \2 ����W��v���#�N�@�ޟ( 㵊A�d �t#�w�M�����[����zt���$���o�����^'��Vъ�h��hmpg���wm�e�h���W�ݷx���U��R�%�K�jמ�p��<tp7��PB)!�	���EfZv�ۗ�I�'��mY�5�w�m����6n|�E��14�HiȥJ���m³ZdU#.�� l�b�5����I�����( ������R�3�~c���إ��>�<w�|j�ؓO��3�T3�@h�um�����(4�QX�4�c���7u�Rl57��d%$4�5�h�r����mK����a��h/�8.g�n(����œ��o�.Pc0��vaq)ʿ�����.��(�I��q��n�gvҫVc��Æ�M�P13�=�NB_�T��*���߷����0⒦̅��h��ñ������Ԑo馓5���H��5��;jN{���Y�?��]�B�f�֔i͵-c��v�b��:���[8A�ꢖUlQ�X:�v`w�Y���l��qGug,/L��,:'�����"��q�®LD���N� �m#���x�"��Fy�P�[�u%j�'�˸]K��}�~D0S׍���٫�R.�1IM9�"�f�Mw���`9���圹���j�S���T����T����(
�y%KMd$�7G�i64����[�A�k�l�
,��rT��v��ZI�~���r/��ᴟ-����j�/փ���]M�xs3ض2��_��_S��Q�_P��N�_MݱH]���_���Ɔ�@Q�����YQ_�Q�K{���ˊ[�Y�2K�m.2��nY���d
[9;:�RS�F���2u��{n�6�$��wV�f���mi��^��E�m�n����á���5�zDl�m��+��Z:j�n�V�5����~��z�ntw���^�ۺc"�Hn�,�W��d��B��2��u����f�X���(.Q�ӻ�Emp;�� �{�e�,�x4P[w)޵�H-���^"eצ�1�֗�3�ң�R��&fS��p��l����8����8�?v�@�T{oAm��nz�m��������S��A<��@͙|ٹM㠸f�.�V���-�|���~ۅz`Y���]*�rZ����ݮ�,���V�P�YUR9����
��v����U۽)g�k����a�i���}G�=���Dȯ��x��8�^k�"�/5}FA��:!�����l�e.�����i�&���~��n����N�9,aKŪ㸧b5ӛ��2�<�S�������hȐ��\����!���y������P�!��-ɕ[Uj��qr��Mh2��7x���铣�PK    �{?f��Fy  ^B     lib/Excel/Writer/XLSX/Format.pm�iwG�E#�H[��DF���.yy`6싳z�QK<�zft�8�}����S��ux`u]]]WW�r�s}Fz�q�r�w�wc�>�|���"�sw�yc'��5�2"��}���#Z�/�wv���?;����>9!�G��LN�l���?�����0�ّT�#6&�O�����N�>Y��l��4�ܝ�br��v�����)�����)�{����ůϝ����O�Y�$s��T�B'����φC��$#G�n�v�ŧ�Up������N,_R�ˊ�S�C��N�p��Ż�?�i���������^�y�f�sx�T�'�/߼|sr�L��7>[��J}>�#q���(!�|��A��k�+�n@��;AS���&0�Y��p5�������&�A�{;)��̇r��`B	<�d�'��!��3	=PFO��7O�玸۴�"�w���JF�7�#��10u��N��3��+#�Ur���K�^� �+� 1,J�gt,k�;��j���]om��y�3�<bq��3Cߜ�~�퍈Sx��u(�t��[�x��<�8�fpWm䘭��l[7�S	��ӰL\�Q~L�<)�y��O����1i!6�BXe�/�:��y%{���'H�� �(�`��W�L'qʷP�K�e:q̫���P�K�f���e՗��`\%szlR`V�U��rJӤ�8͔�
�4�hJ+���U�F3^p�3>eCN�)+���1$���n��:��4�l�J #�AR9dO��K�A�y ��,"!��W����Q\��t<Vy�R	N�O!����rh=��;!χj
��<C���l)�:P��v�4mS��h\�İ�`B�� ���H0�Ȝ��24�V��d�4C�a�u@v��v�B�Z{��(W��`����h�I}��ۤ�㌫��#��MMps,��F>\.`k!`� ���]�ZÐz�P	~��ƫ���ғ�3�A�r5��(�۸�Š@�ɱ��.yˢ�ⲤZl���8O�Ʒf�Sp��l�V��wX�S����}"(�\��.�3��m�e��2R���*� Q{y��x��CNg̹F/���IHb������j�]02b��� ��5�լ �Z��Ov	pC�Hw'�d(g���[ ��[��k�oG2EJ-�������]b��?��f�t��b�V-�i/d�q!��n�,A�hY����C	H=�9s���H�1Qy�`�!/&č;7X�8�D�!�8��3��
\_�>4�b�3�������mj������bz�C{p;��Df���U�� ~��T����B��'q;�&l�xI�.X'����4 PK��1Y*�<T��71:R�~��Ý����c��,5�,?�������7�S�g�p�O�O�M��������h�B�i�.ׄOh�MmR��PfU�L
м����D$h�F������v�|���GiZ��̎62��p�G�%�bfs�i�نZ�K8��� ,{6�4���2��Is���Y�1^�ʚ����c��0���D\�
[|�ǀ�#�ޙ2�(��~�C������fUőM�l��7��&�Y���"k{%�dN�$��Rq��p���A;.�'6#3Z*�K����f�,�����+���*ܗΩ*�7X��<W�T�K����������t��Ղr�D��~ٝ���%y�JJj�R��)�E�e�H�av:P�H�w�n�x� ����T�d� ���M�k�Ψ�b⻟��� \�� zGހ�XKۚ�f�"ր|�h��RZ���7{�q�M*�M�J�l
W�UO�.{��`Ѳ��xFٸ�֗A�"�l�t�oTc��sq��vMK�Moo\��y���R���a9P�F�}[����zb������f)J�J@5T'Æ��"���� ���� ����u�Qj@5�?������r�Q%۟���h�X��t��B�kM�;��u��;�ٮ��8D�~��*/�q�ؘ_�V�bΠ��.`c��%@�#�?N ��O�#�;�Tʻ8Vt;�GT�d�`�J��u<���"���b)�?�4�P0z,�!����r	@�;���.Բ��I>��~J(�+�`.R�t��/�<�\�6 a)ũ���׀�u�2�S|Ƞ(�S�$qf�[�r�6s�� V	`���u���-q��|��XY�Á�U�G) T�Qph�&<�4E�a
�L����OR@�z}��=J˙3C�c
X3�Pj��^&l�j�Y��]@���d�vF��-ܳ���(����^�����7`S�3�w��}&�Ӓ,I��c[�)1�@��[X������	��>]\��J��?������Ғ<@Ƞ��� ��­`Ar���җ��,����0�(6�Bf��"w�J�j�%˧�у��B��a��X�)�����!�N�Ɇ5^'��?"��)�,�:p:����...�0!���:pi��IX�
�A�:q�3V+Z��7��tۥi,��{��O�(��̋X=.BSlS���m�Xh�j�����9���&�@8��GY%*�]�A����¯m�9"��p��AzO�b�㍡L����Cx����Ӻ&��-81��3���q=�a!v�8�jR�7�>(#�}���(E�x�Q���m�}T��!uxE_́�o� ^x4�{la\/ٔ:�N=��e�.��J��P�0
�c�����|�5�f媿{�}#Ϣ֥�M]��E�[,j]���>���)���@Z�T�z�X�:�b�!m`P�$cE��.�|z�-�|�!�3�Y�A].ρ��d�i�aI�i��d�8лpT!#/�"5��Ӵu����Sۢ<�e�o���CL$�T_&&*-��ӛ�:˓��L�b�!X�^Z�ņ�C]���B��j���T.o	�2�hW/��kS���W�dx�qcXM�x����;�����(�!���Te�}8�YU9o.�G�l7����$N�����|���/���;v��ڍ��)��Y`�Qrp��B�,"z�X�	L�Pf����hkW�B���T�W�XDX�s&�&�t�.����Ko���&�,��x�b��(֙5`Q�����T5��9�\�Ū�UN���Q�z���z�*�4v��7���$��mcmS�����1�6fT�y"/`�dG1rtȉ�^@%����r{��՜�i"�$Ȉ;b�9�?�w�$�m�z��g�ֳ������ո}5���_�~=g�I����v���
�<�;ԗS��d:�ΧɆPP/�Z��"�҈T�l� �g�o#��c|�g��-�GG��}�������|��=��Y��#^F�OH]/��<$�"�"�4��B"Bڐ��q\*��,���[��
��\O(w_�C�a���図7��,������Vˀ_wȅ��*b9��H�^x���[jcۑ�n��?��mb>̘;TqV*�3����%0U.�W?[M���/Ή��"���W����E9����6_�}g!�{2B���<�b[�J�h|&��3@-��W^{d��)�bԙ�2���E�_�{�ēoZHc�A&<��Keh��Yg�!��8M8�4;�����?It�������^ ���@�(k�딉� �����Nd۸�<�=U�XHk����C��/g2�5\��%�(�~њ_�X|�ß$���җ�z�U�E��a}`�F}R������id�6;�.�Z䓇�,��{YqA�J����G��S;�%��+2Sr}ڑ_�]��x�:rsqOͽ�z��A�z�^j����S���4B���Ɯ���|��?��l����
�J��ci�. ��£=�v`��s�^7Tj�p�����u���>�8v��޿���Nr�4W~�����,�� =knJԅ��l�˭B�7�I����.�T�NY�|����	���ħ��3�Z�e *0-������"��ƹC~��E�&A��"��ᝰ�B_f�~��Ai�`_ꪇ�ș�vJ���X�G�9��HLG���(dL7	�<b����=��R*�[w��~��.�aq��e �̄ɝk��vmVfe`dB���}�(ꭡ��FK�u��1�B���F L��� �q�4(m�bNMrSR��VEza�W�t��Z��F��R�[�uDz_���A�k�J��I�[�0�iԖ-�ʉcǎ��@�����PK    �{?_�f"�  �!  $   lib/Excel/Writer/XLSX/Package/App.pm�ZYo�8~����,|�>�#A`�hڠI��D�jdQ)����}���#v��@�Ks��p����)����E����4|~s�ypC�2��� �˃N��Aq�ǚu<���q�<#���y�k?��=8�#���BX��?����t�����h_�~�����_#�.�a�E�Z��9Cw�p<{��Ѩ�����[�$!��ץ嫯�V@�>�J�Yђ��(+�A�`��o/L�������=��;���Z��R�����y'����z>�H�q
���z4��'.B�����>���霄���|�>_�Y+
�E!�^ݞ������ᎲG%�����۫woQ���_���L��f�k�mBwE���+XR�`6W!��V�Y�OׇGq����,���h&�����X,�������'�9��#՛*��WI��O�&n ��@��ԙ�
3��f�r_�XPbc
"�"SG2L�:�6�/3���c7^mL	��B_�&�MK�0� �MGM,�,qh���*�Pj�"�i����磧/�����E1B���lS�&T�eRÒ,�\�cmĭ���lf��Z><�sp��*-4TO/dA=�p��d�J��%�1y�z�ŖXt<�3큛Q`
f�Xֱ !����(+�Re-�?�v#�抆<��vg��Է�����4B$�X <Ɠ��Y�}��Py'�	}�e�5�/��#Ωx� �G��%MI����mg�"�F���'_s����3��Y�G��vA���;b��¼S�bd;-�����
V��q_��S}��ts�-��5�!�[s#tn�A�	�\�Ǎ.���$�����{��2�KP�-ףYhA��ʖ��M���'2��>)�e A��t�r\����s���tDS��ĩ/`x���ڲ��=�w�ֺ �(�r�+C�������;jJ�ҡ�9��b�p*
�^���B��7��q��.
6D��y2�b�k����@{ \�X�|��~m�l���s���P�?���_�	7�Q��i��kS���Z�$�b,�ƃ�~����Ǿ��%�z�S؀9�k�d����Ȕ!�ϵ�Dq�]�J�^�[Y�\���4�V��[ɞ+"p2�EB혬`J���Oc��u�FFE��B���\`���݂��o1
}e9!�2bSF�����-+3�µ�](g�������v��;��P��l���2D���1�	����1�I��1ɏeDn%�IMxd»g�C<Nw͓ԃ="R�ʠ�}�l��kAŖ!��j�7f�Pll%L�� ���.�D��9�a<�m��(Z�\O�9�4b^��3��e��SE�-�_�K��ts�<�����5���v�t�/���l�}"�oN�.ᮮ��xgNW"�cMj�r*���9#S{�������ȑ�N_��\c!�H���+��E�}E��4)4վ���$�����\�n���x���䡣߲�2)��#J�ʃ�
c]������\�@j'�Ki�V\��������ڣSu�$]gZ�o����39�����tC);��	����;ׄ�����k�������` Ʈ�H������ҵ&4���,J��M��R�&nC.vw��U/�����;v��& �jZ�q����]�W:EÉ���O����������Pi�S�s��8T���Tţ="V����ᣦ=s合���/~����؋2.#��x����0^�v�PK    �{?5\�h_  o   -   lib/Excel/Writer/XLSX/Package/ContentTypes.pm�ZmO�8��_a��
ڶi����Bb��i�E���JU&qi�$���Z��o��&NZ�e�����yf����(L���G�D�
¼���z�ؿ�w�;�� ���H	��N+��D�C-3J���H�E�Q������l` ��G�s4��A"L�U�2�F�Ff��n�4�HOM�'
���[��"�	��bVg�8�邅w3���~��?t�t�����1��-����Oqң�N���~�X͂��M&g�'�CJX$�`�-����(�s�$�J)>D��6::@�T�Q7�n�2Nл^ �G��B�c��
��N1K���n����\Q d�1t|~u����3�k(�?R�o�>�����ȶ���wmй��1� � ~�9Z���i:��"W�Q�+T��$�є$�qc������ҁ���t:}b��F@�8�{-	�5j3�v�l`O+�|��-�n������T6ò����a,Hi6��d4�����,�'��z	�)0&BR1b�ʧ��܅H�:-����"�r�[SgO��"⨧%�tA�D��]�Z'<�������)�"��b&o� l'O�[@�$@)� ����D�h���9/�P.#!�}S�(y�/(����V����D��%�d�
��$��,nXкc5�H�U�����&>��A�OGe��O��:���-O�'Ŗ?ޘ	o!T�f�%
#"c�&�ZO[��	LH`"щ�F��O̸
)������VbR�/B���*.+K�/���U��a���jX�<H�$�L=5det�P�>�=�V��6�����/�I��o��m�3�"ݵR�cW�xGħL�����}9���^$�u��� @$"��q$�Zh�f}�����J�O%cS���W��ꛓ��؉�4�3t��.)�:P���;��~[u��������J;�3|Y�\?ۙr�U�����R�F�X:E�lx��z��+~t�ʞ�Rw��A�r��'���b�U��%N ��>�l�z�3�@-�6@�Q�*W���JV`-�-��\�Dc��r�X�6�is�V�S��W�4E�9 ��܂�:�7��G�0m�AQmSJ2M!a� �"�E����>��	�	�L.�AB�4Ear�e�Ϝ��=���E#��iQ)��R]��/+A�8���S9���܇���/{߅1\P텦�<E�gn�8J>*HV��M�_4�:���~��Wg�=tO�r탾�[��꠶2�k��s�yښ��!rX���v:��{=U��]�h�(��_�^3����I/�)����T�z����Žxy�S��7�G~���B���3�5�p7�@0�;���8l�Z��s�mpcCI�5��W���x>�z|����x{���.D�p�m��}���V�}?���b���7��N8�'��7�[%���gB�C����Ę;�#��,ϴ佃~�7���j��(��8C�fB�5Po�FGc3W��q�U�uJ����EG�[W祵��7��-s��5����d*�N�t\�e����TL��4ߚ����]��k��*F��Z���,��y��-�up�u8�����\�:<�}g��U�d�k��ֿPK    �{?�:��    %   lib/Excel/Writer/XLSX/Package/Core.pm�Y{o�6�_��H[(A-KN�n�� Y���l-:CѶR�FRu���}G�zZr8�Z'�e���{��0�)���O���[��w/���kL>�9��'����H�����c]W�]W�]W�ǆ��~_�!)Y��s�f	CKP"��H,�^H�����S�Yҡb��S1��,&"Hb�Ģk9z�tł�B�S�q�Sg4�ߓE�^��8��]Db�xNR6W�/�E4X͂g y����t ���"�W�R�Y��R.%I%w�݆�Sd�b� +NBl�����F�X}�D��K�b��o�1K��{���RQ�mI���������<�Jޓ��}���ӫ7���t��OM���X��nÀ �(e�G,(���B������<�~���񉎷|��0�>�n%}6�h��a?A|����0��L:�+=e��9ǹ\�m�}�r��^��>�����%�"�|]?�[�0!B<�뚸�Q9||���*܆��8z��¨�X����zO.�`B
�F=����#z\E���JU�dYW��6��NS�)}V_VW�y��|TI�)؆��2ԓe����M�O<��*���K'�b�n:h񁮖	����)',Pe�WD���f���U�0�X�s���TH띓��y�z�R���u�Ce�xoYg4�o���$u�S�K������^�TΌe|r2�� C�w���5✊7�H3�uF�\��,�T4bO�N�P�uGD�L�&�F�ţU�j���,T�:���p��b~}�*؞H��'?=sF�Q���`>�5\�H`�j�Iؐ���~ɱ���8����)|���)��g1Z�$d�]�g\
:�dH`�C���8T>-`�"?}�����\Q��	�>�f*�Ka?�Y���'h��ܐ���U�j�7��=���9��ۍ|s˷�GzƚR#��R�Ji����qQ��~����~��o�N��Fy>C4��P�A�'��1
=;�֔�����"um���0��@p������`�3�G�g6XC a[NmUS��9|RV�b�4c���[/�ۣ���`V�Y���@�R��U�7?��r�.�(VX�Ȇ�*Yl�qL�Y��9p⹕� "��bwi*�.I��g�m�O6a>逩�M����K6�|lV0���X���W�5���Y��g���
��'���eT���L�I [xGg��8�'� ��k:)�2��W�g����s[�Q�$�����R����Kn�{@�nl�7�P\�ņ��-h�)����S�[�J ��j��}����o���Ρ8{�o�4���4B��[+Iz����Β���g��M� ����%G�o��ߖ���׭��/'::��l�'��kTB��75�������j�2]ys�a<M�b>��ՀZ̽�P�:��W�� ni�dW;rv7dMc㞯#$k�-aYC�jR�D� t/�Y���Y�Rv�f5q�9VCv6��s/�Y;�%[׹��
2U���uQ;�P%�~[_@ۺ#��\�ä�@���ǧ�PK    �{?����
  �F  )   lib/Excel/Writer/XLSX/Package/Packager.pm�\mo����_��\!�� haA�_
�hsA|m�A�+�1E2$U��߻�;�ܥ(G�|�:@Lqgfgv�}�U~�&F������OeR�r����G��6���w9,�?�
�1��S.zJNO��z(��ދ����?$ͣ�EiXUh��(*qX'���AD�B��!��W�c�d(ʳ��,��<CwI�pE�.��Ln5z5�O^�'�c��|��F��eX����2���yT��0/o��/y�Z�Y-�FA���/A@ʉ@�˴N��u{��i~G���U����u:{�N�z6F'Y���ު���p<!���SU�IT�绰̈��z{_�eM�A?]�e�����$U4<)ז�7E�E�"�j�o��ɗ���G��V�I����",q|IZ4D�B��v���^�{��D��.� �3C�����������x������?�z�'J����4�P�Ũ(���5Fo>�CK\/�b��q���#�w�#��2��UT�%u�Z]�B��ף��|@?�~?Cs�{���霼��^П@�� NJ�fv���c-p����y~+_P�U�9�����R2_�,#\(�WY�Ơ<"�����\�
`y\����UN]��2�n����5}�&�x�&MW�zUf�h�[�)�AE��پ�5c?F׿~������x� �@D��C@�w'gߡ�Z��-�0��D�o�XL6�|�̯���Q�3Y0r���F��28Y�m�CX���w-N[����5ÐѤRp-�U�SSԱf����Z p�*
Ӱl�ƻs��7��گ/�`GZq5JE��ɇli��-%?0!Z5:D�̉�6B��
��)�l5@.�/�Jr��pJ7�	�����/l�e/=�u��)���JE>�5Z���
A�/!e��b�����R�+�u���Z�/���&�6	����v��OwZ����4"���b6�j:�k���T�E��3���2��$hݐ��r<Jps�6�ʔ��(U'K:���'j�.$K��/����v�-��Eϧ��c�9HQ��n�=ft�����/���_6�� ��� ��`�}$���d��f$`� )8�V�H
�����o:���|?�#U̯21�'uL���2|_��m�N��
1���g�~�I��K*c �Q�=�}㈅"-������8��?�V_��L ��#�ڀ����#֛"S�D�i��P�p<��)�q���m��~@�X�N*��	Csp���ƈ\v@��'`Ii"El�iJ>lƋ�〈q.C,�Tpc�7u�Q)݊��m�{|r��%7�S��:�Ô~pMt�^H]Lx�ʒo+�A��qqX��ZaY��>�}=Cc��$��v�j %�G�q����Ô�� ��p��Y�o^� L߮� �z����M
|��:��;�����2/pY'l�COyh1�K���l<j����
E�z���-pS&-¤$KdH�2��Ҁ�����W!���*t� �����-+嚰����FeAŇO�DR������-����;8��i�Ҁ{���L}�1����#��u��m�����<�����}bk�o�p�!Vt���ʕ�����~���L��;�Q\20�GQ�uR�䊑�LM�©�:� �WF��G�J�1;u�#�Ӄ�����[�
�����a����P�;��a�q�ċ�� �;dX�jfZ�0�����g�)�*`�g��ҫ)�ކŻ�z�9�� �CN�}��c{O�c`�~�f֢[�Q�Հ�:���cBB����s�jn\4��.��	���Y'�-UIIQ����|p�O�0)M/yO�-�_Y ��H2�C盖bm>�+с5jY/�}�.`��f7U��8�������Z�w�����nw˰��F:� 9��5ެ*�Z3�.NK�Rhg��pG��ڶ �q��1.�>PF��i�� SVU�/��4/�6mCp� z2�y�����
3�6(�"�v��+p�oFIC�5��N(�mͨ�/�9�9B�nw�61iB��#�Q�6��v�q�	Q�n�f@9ߏ��.��r����g�1��5V4����δ��3����9h'��2ĭk*�l���(�ϓ�K�d���� �d0��%�C:�`k�ME�bi�X�8�{���db�ذ,�Es7���?��.�l�զ�g���1���ԁWP]0��N�:��Dݱ�r��/��8��u��:�X��[oAS|:&�n^����%kJq�V'����{
��>^s>�����y��{]��"?`��^#�ߑ�+ːd,M�ۊ�'�J��)�ǲY��
+�x��BbRČ<x�^D�ε��:,�630�O�Z]��f�R	H��d�h˓h���+z�^6x�w���2�DL�8��/K�嵼OcV�^�v1�	'��$�[%����O����o�󖛷���!*8�2�T����;Dme~�=h$�m�4� �s`����GM�[�ڋ�]�{�'?�*%��o��1ڤW#z����6eӂ+�6�*Jm���N�[^��H�h��X���CРyI������6lwL�1���B��X<�<��7y{�L%�u��XQ�ep��b�4�)\4�� ���C��7�M�єl|�T�����s��ǳ�و��.�n���d���:���|�/�I1�����]���%���om��� ��W���z�� ���,*&vr�e|55��tE�rɌ���B�N�@����a�m71=�;�o��6JO������i������PK    �{?6�BT!  �  .   lib/Excel/Writer/XLSX/Package/Relationships.pm�Xmo�6��_qh�Fm�e�س��͇M4��(Z�-����\#�ߑ�d˖�`�Q��"�x��<w�r�Č� ^]}h��,bEE����C��Ȃ�>҄��3ř�����Y���:�F�k4*�F����q�^����ր.\B�)a�,1��-@EE���.h���?%!fp���@��2VQ���[��D����~w�:����$%�t�1�y�2�<.���2eB2G`����w��v��Q��8\�t�s�$|���3��t�Y2B7S�>tO�����?���c�&��e��D0����-�}:������� w<pq}	�7����g�����������n���{�7n�y.������ۍ��F���H�g�}Od4%J�\�f!C��Ծ58�^1��T���b)A�����q@K�N��|��B&���pyw)U����z�}0�l���a(�<P\��e>�FxrM~��s[����Q�尤�\3�L�u�fͱ�5���o�k��YH��9�k��/_wLq�.�9(0g	�8̈́NuaT�Y��Y�(�>.H�P�����H�e1ndc6l	���z:����,�tW$lo+g��o���i;j�C���V�Sju�	;]��Я�}{�2oa�E�@�=�G���+�I�I�!轔¾��*���D,��!a3{�qy�X$��.�
�,�\<�j~݁/ֽS�~=1e�~y*��O���9t�}�x���9%K.�Ɉ҃�QM�#Ō#������6ss�h�s��<�?��:�0NI�5�v�H����	U����m�4�f���:��}�L�&Tk�*���8�q��(���rE���.��.L������CݩDy�Od��� �Nm�@^�0V\�������z��G_�Ѷ��>eaSpU<x�L�,/:��#��i��=H����������+�C��\���i��:�U吖�K�9J���v_��6��еpSp�~�j��ׯ;���06�ε�u�d��/z�1�k�zDG��u�������k#k���Z��s�t�^��S~�;g�/�_~s�PK    �{?)���    .   lib/Excel/Writer/XLSX/Package/SharedStrings.pm�Xmo�6��_qh��l�1��#A��4��5���DY�$J%��A���Iɒ��e@=�ȼ�s�y�A�8�cxq�%���^0E�w�vr�ݒ�o2��$&��%��~��pr+c��������f�߲9����8��=��$DJ�2�A�e���2�XB����8�/x�X�a�T��1����求�`0���]�%�9\7$%�t�>�y<r�����7YP��+bv!:������t�rTȩHlA�%I��x�\[Iz�,9B/W���,!�SH
���c�h02�$"�}^�m5��"r��t!��.���ή&�?��i�y������q�����ں���>��b�� !�3Q�o� �*�BiJ��w�N���okY*:|Y̴G�"}�C��S�8���ղ�I����J��fϑ�k�{�ǩ.��<�Ѩ�#mW-+�?�ڪ0���%*��g�
ڒ�YB�Q�8K���܊F�rOU��ۍN���TeQ��uC4�"ӭ���Ѣ�i߬�)ЪlMX��7�Ю�]5�C���X)u��**)(2�am�����P�]:ڱIɃ�T4���I&�1��[��S�F�pQυm�md�{(S��֠��x��T�+T^��Qo譴���&�j��ڄ*�Pe�$�<�QZQm��_���7K���l�i+�,���Uj��s��3��J°&�=7�Р$B���H#-U:̨a���>Bj'�����xűS8쇻`�Q]��?P�X��miU�'�8�P=g�8���`P�٘lc풶�os�b����+���g�e?�)�[���(��c��E�����>���%��)Ui�����K	��h��(���PT�C����n�u\nӭ���Yh(X�VM+4S`�v�N��TD����畲��]#L�>)Y#7i��H�~��ׁ��-���J�ژ�:+��Z^�!;��-M�v���B�M`Ql��Ѵ���F�x?H�~m�}��^+�y!��.:�|�%��S�UGR�uR��T�nLz��łxug�լP3'�W��h�Ǐ'b���/۫'��9��Ŧ���Fu
Л2&��
��OI7��pE.m������F�>��zD�yӬ=֯���s`~t����PK    �{?%QL�  �R  '   lib/Excel/Writer/XLSX/Package/Styles.pm�ks�6����dƒe7�\��ǎ���5I�z&��P$$1�H��h��~�I��|�z�͵&v���vAP��0�l��{~��h��4<�9��|��_xS��A�D<,���r�������G��}���/'lm����l���$������el���
	�)3%C�X&q'a�4�׌,����_��a��P�l�	'��&�3����ao�������b���ͽ��f_�~L>�^<H�)M=M�|�c�o��h����hp@X�4ap#%@�'I%W��d���}֟���=�_��!��I�mm�g?�� ����2����_yi$2�t��W���_��"�-�S���c����W:�}x@s�����/߾����`�м_x����g^�E^z���w/ٜ�Ydd�o��n�����`��I��g���ϭ-����}/���e�p���&0��R�#�����џ#	\��C���T� ��Ȗ��^ą��O��b1�<K�4����\1-0�8�$xjRj�@*�V���L$s���T.Q
MXcH(���V�P���<�%�`kyG�2�r]�#\W�s��)Ȏ�R��:��75�Υ���-��<.nxJՁ�(Q8�&�ܧp@�  �(-���2��#k��~�K_C.U>h�@�2�u:��u�S�k�S`�"�1c<�	�&+�t�v��I+�S
���Iu��6_m���S	��E\�κ�?��	 ùu	�aL>����=��	C�B����Go����������k�)K�_�/(h1g���>�gN�x��EA�?��.�(e\(�[�	T2"D��]7((�p�g�j�-3�񔕳X�E�HX��-���e�"g��S
q�>eómU6<�veómYV��mˆgۺ�]mH/cp�؋�yU�"���TYY�]���I���eUGET�rC�w��o=�de������ϞI �{�܉���<�hH��S|��+`�^�s2�'��8I.�MBC�F��RL@�@#��x�ΟŪU~������z�;E4�@�Lu[���Ҩn�<M�c��Z���'I�3+�������!�h1��	L�#�_<�K-A,&���ٿ�{����m��t���ń	KF�r}R�mG�n�\�1��?�j1Ɔ�7b�����3>����`E�m���{�G;Б?ޙ{a�+۠���Vx��$a'&�=vxT0r�<��L�75���
͇w�7���ҵ�w�����bb��Fb�}c����k�5���%�N�V�j*�V�#f� �@��W% r`i K��Ќ$�r')��y�>$�jW���l�'l�񣁞�k��!Qk����dG�8�@O��'Zil��D���d�\���+�B��`���_۞f���(,@��o���V�Y��e�C~G&��=I�(KO7XI,����Bܘ��trQn�04�o�T�Z����C�@<�.(SL�����̻$���	���V7��3~g^Fˮ�+W���{G�sX"���.�e�^�X�2CU��$
��v� ��B�	<���D�J��@B�\t!h�N���"���d�yAr唉�eu��<���$7��B�^z��2�U����!	��b�5}Oc�=�N?��p!��@h�a�=XMn\���$����? ���s�������n|��cr�N�Ĥ��$";R�#D�!%���y�i.�)�p�����5���X�[8褊�&TD�k�nwu1c������aJ��yLf�x�0��ڑ|B�k�lp�_Y�m�B���]%��,��/��v��O:q�%�k�~:���K�zF�o"eF1w��fR"Yk�ƦR��AFY�N~��5�B.���^��}�s{A��#޳Gf���?v����4��>�D�w7ڏ֐��6wSyx �y�β�ܖd-�:�Ź�������t$�\�o�Ԓ�� �E���Ad�S"E�Ne�w�]�yTj���]��㼲��A^��	�j-��J�9�Gm㝘|qب�q�Yl#�V�X����wb(T�N�8�F�����d�}>�˼ڊ9M��ݽ�z�>���>�Dk��{H��{�h���EIIu�f5�5��wl�'�p	(����K��Q�8����#0Ĳ�"@=�<���W[Œ8�zw��nk�j{�F�%�x:��!Ũ�8�"NJ�2S).����b3��3K�0P�y����@��c���j�_�4�v|/2�7�~e�4����_Z|���(
3�i����И���5#%��D�UV*O���O&׈���h%��2��YX�͑��RT��j�
_��ZӃZZ�rr�8��NOTIP��u"KS��U�q7���7��W'�ր��J�x@�?��f�n��o8]�[V��� ��Y\�E�U����+.%X��Kb�u�d�^�H�εO��M9��_���Qݸ��&��oo�=�i�P
����DS�"S�6� �4�"�f����b��vR��L+����q߻�o)�-�Q�xgy�e�x���yE̅]g��8F��r�<n��
��0�=Ў��ėͬ@�����2c#�t�8��02���kw|�qhe��0+�rqY:!�d�V�чv��s$�mY�dag ;; ܖ�8"���I����ݖk>v����ZX�7��Ƃ�������Ϙ��'�5G��	��Å_�4�Iw(9(�4��DK�"��U�䘐��D�����h�dye��|��*��Y�>N�¢�m�n����8�~���౶z�yaZ!uZ���h �c
ÁTg��bj�ɲm-�@X��
�$���SH*��b��Xz��^�u��>5����\$]_������k[4N���6��kt�߼�0��B���8�/ˌ�]a�!�9Ͷ�bV[Y�w����ͦ�nW"�{���wb�n&.��[Y,������Ưk{Wȸ�-\�h�dn~r=i��:���7�G�R�����j����2��
y�q��=Ɩ[��q�QId�A.%3�R����p��דM�s�ؼ��N;�v�]��zH�x� u��oj��a�T;�W�����]sK<đ��-�E����ᰄq=��%Zv��ֆ�r�٪ӈ��XD7o躹�<�Z���e	�o#h"(��Yq��g�L�v��&��u��v�ZC��$^-6�vZ!v�mp�U���Gg���=��V���#T����YC�g�k��y2��EU$� �����ǐ�D	b$#�241�R�>4c��|�y�`��?�6��$�6����౪˔ �*�����Ii�ʃ3��d�<�&�c�#��r�4�I���5�V�c݃%	Sy���U���鷄ؔLқ��	�NO�5N2ki�~��D?6b�3CaR�5S��-���_U��F�i�����@����.̔p�hɕ�Fy*j/ȩ�V�E�
˺}����rc�k[�ڡo�?iZ��3��/�յn�gU�9M��b��|�`�7�͢����'�	]�>gu�����#��Z��1+n������=��6݂�uY1X�ȭ����
�i5U̣�.�A\Z3	8o�� 8��"_�g3�`�|�r����{�)��2�w�HS^������O��Pv��W��Ų�J��"|sR)Wu�!��f�o��l��h���r��4��*��Q;���&����*�N!a:���ӼXz]��s�wkCʆ� vR���j:O2��a,���#��~ﴤ���r��W�<�?���+.]Dȴ;4rݰ/^� T��~1[D��k��p��ӧ9+�VW���/GKN�$�1����P�RZ=�/yh��s������h�SV׀~���V�[��#��?��/PK    �{?�<N�	  &  &   lib/Excel/Writer/XLSX/Package/Theme.pm�Zmo���Oq`
�bQ���DnmYn�Ďa;i
0N�I<��c�v�����0`X7�̀�ۋa[�؛��d�u@���w$%�:%Nc�%�ɻ�����}�ш�:r�=���UD���<r��w���=HH�q�T�tl����]��v3x�k�*�k����?dx�e��<��D#.��A�1RA��
e�e�jHH�#!�G�I�)�#tFU`���y<t(Ԩ�jˍZ�~}ʃ�x�8��@ǡ�ˏ�GU.Ɔt�{IH"��<���h��yt� ��`���T���3�ϴ<�T����!�5�r�z5�q�+W������.8��̭>'2ZRH�	Ry�`E
Vڷ��㐡X��a�z��	8���H*���
'R�8�0����OF8a*eVM���ӈi�SF#�QF�V�`I��c,�7!?&�D�,�|HQ?� SN�X�=�hU� _$T�V*�$�]��!ҵ[�N*A=�^�as���\@Hӻ>qz�}���q�]�F���������C_�}��_�e6?x8�?ؾ��K�j��t늢����|=��\��F!Q��)�K�z5vD����Y�B��ă|���d�7ѓJE;;���t�!��r�.	��td�R��J"����6dH�F�(�D%"J�nU��"3�@ �@� ��tgV�g�&�F}S��v�M����<}�1��~��J����kO2�^ɖ��#Sg�nW�	I�1"U%s�Qi������8��>�����7e17����B�|��o�|Gˆ�O,6
`1��k:ig�h�l	]Oy����y�|�,�Id�*�/<�?��i�FA��4
��I`���g��i$A/CwU�ڎ@J�~�:K��y��)o)I�n�����64N��<�� ��?f�CCMz�6Z�m��Cf��HkpJ��Y��ԫ5���>���<8�Z�8���ƌG��L�t>Z���ݔ%�Ì�{N�T�u]��2�U]=�#��������0ȭ�z�p�.��s4�IgEg-g>`DOoR/xLxFb��`����%'��:Ŭ������A�]l����8��mwJ���ݖ�dt��0tb<�ַZ�77��)�y�`0��S~�=,��a[[��Fγ J/�y�k�Z��/�o��W766ګ%|s�o��;���z��o���y�7�����=ï��n����x
�|t2���Ff
����x'O��-dWJ�E��c.� `��v��$��� ���PP��.���tɓsKZ���p�p>���S��|��ϿA/�?{���O��⫯^<������E����������?�����c��"����?��k;P����ٿ�}���~��?}m��<,�i'�]��y�Y��x3�� � iTP�N0��6H�y��ۀ�$�%]�(j��p�s���՜�ZVќ$ۅ�������&�.��$�L�6������cm<&Ltz��b!��Ғ_w(LN�����L�.9�Ce'�CC��Ħ ��䛝�h�3�MrZFBA`fcIXɍ��D�Ъ1Yy�����Dx%��Q�������Fs_LJ���Љ�a�a�����ؐ�0�E�&?���6�i���R�=��J�r��{����!%������;�Ⱥv���4zU3f���f�����d+��-x�l��8������������Z�h��5X�8~��!έ�@M�'Mk�������Mg�8��L\	7�\#��gT�AL�Hˌ�X��K8	8y��$��Z;?������p��܍eQPS3����ͷVO��Voۥ�_)�-x�a}�4Rѐ1�_�=e����C$�,Fu�!����y��
�V�o'�"A*�k-׾�(���Η#��w��j7��p�sF0I�e?�f��x*3��|�`{Z�k.���T�X)��ʿ:�f�7�-��1�ҍ.�E�S��pχ��F�SVf��O���,��n���S	όF~#�B[Y�+?���_�dՁY�'u
�O��z���+��.���ҼDS�?]St�����́
� ���ўÅ
��8�ޖ�������V	1�}�֕���V�#mr�@��1:�
!{*��5����5g�����2N�)a��zW��
�n�9���͵U�p��<��L>�f�Zo2��
M��(X};��Q۰[�h_�Q���и���l�=��}4�($�r'+���t��Ӭ�v����� ޗ9|��\��W����n[|�~����us7���A�f��N��&=��f?e |��Z%�VI_��BG$G���K_���_���T�����j�PK    �{?��  �	  *   lib/Excel/Writer/XLSX/Package/XMLwriter.pm�Vmk�J��_qhVP�����l��tm�u��'f��Lv2ٴ����yI�E��pA2sޞy�9G�9p4y�)?{TLSu�t3:�#�Yӳ�o7�����Q��]��a���D���e3����	�M~��%,IA!�( �
tz��H��M�(�
��X��RĚI��6`,�7�֩��~��=��[���3�E:��¾~�s"zR�m蕌ˌ
Ml�0Q4�]E��!��k�zs�1ɹ��X��MTB7[��9ts=�CWHN��������?��B+k�^%0E�V��\*{3f5&*wo��0�f��^�t�s��&$������%�g?�ӺN{h�'�'������~��K�>E�V�mUi(c-���\#l�������ifE�$��/(Op{����J��	l�גS�����[ե�4��tʨ�:z͸�O<����gO�M[��3�u�q]��_Q0�m�L`� �����R�:�8UJ*�C�
[K),*aqJ�#g,є�]� ���[�ueףSk*�"��{�A���3��Y�m�d�i�Nnhԉ!��K^�\�� �U�J\Ò�Ra�JbU�M���'SR�n��(FP����ڇh�4��D��Ӈ�}dH��I�8��h`#�mH�2IPjAS��ہ�`�!��s����V���}OԖG5z�[�7��ѽ0��߁VՂ�K+I^�h,K�-�C�5�;���`x��?��εZ�֭�*ń��<,u�WkM�c6X�e2���O���F&�?��(���1��Sa��~�x�[<��ax����o��27��V�5��>�AvcE����-��{$�g�н�x�li��is���\Q�+��X��f	j܎�
���=I�����nT�reZԸ��]����ƙG�i�j&+/Dv��N߳t�BڎY��c��?�PK    �{?���wn  �  0   lib/Excel/Writer/XLSX/Package/XMLwriterSimple.pm�XmoG�~�bz�0H�K�Z0�UL�T��Nk���r��%{��ݽ`d���ٗÇ_���~
|����y��݁�r
��1e�2�TF�'��%S]�?�[�y�匶�,r����:�n��u���={A�� �pgh�I:�i�S�!i��3�5ѩ� &Ƨ̺e�|R4��C,�����n���C:�7"_H��A��n�;�}�M�8��OIF$ه/Y��ף8'�%�Ժ���M�L02�F�����h�S�t�,\
zFa"�OA��Ku���Y� ���#AP(
�Z�f���'�ek�}N$��=�s!qi���$
	G�����ռ^�5zV��������ST�[��LW1�ӳ�aSMd")��� �W��sJ1�)��H ��1�±~��&c@�sF��o��fT�D�`[i�0�Ԇ�6���ʩ0�/�Ih���	�PMRfI��̗��bj�R˶s��t^oxrlqka����Q�M�f؍Q
ۥf����+�&(���d�����[�E/k��cx����ܩz�2�N��;�1�UZ�m#��=�#���V�4��Љpg�X��W���_�%�)׈��57���VpuU?|�q��
�V;�c��ꇟ.�6M*<!Lp�T���9n��!eK� �5�<M��$qga��BSUTF������T�L�GtG��Qw4�.��&V��3�TP_����ʵ��_��vժeo��a�l��Q������xF�����OlCH�T?t>aí��\� ���<y��1|(���k�~�f�~F�z��e�^<P���*���2�ƿ4�q�z�%��"��xbn͘	e��%K���AlfFm�R	�d覇w�S���}3DY�M�~Ycq��梲nf*q�'%+	� !w�2?���:�^êO dx�Ao�l��N�[zv��96Y�C�8e��?5����lQ����'�
�g����{�x[~,�2�����|�ݞR}V�(���nb7Ǐ�r��6�ᘊ?�})+�'
�N����r�/����9a�J�9�U���̉"�ۻ[�Ӊ���oȢ?k���ț��u��{*�E5��hګ��wd��6�+��U!n��{99�;�EP�Q�ؿn~i� PK    �{?����%
  �&      lib/Excel/Writer/XLSX/Utility.pm��w�F�w�Ӑ�r˒r�L�Kr��@&W�귱ֱZYr$���o���]ie ���]���13;;߻�{QK�a��z,��Oi�˴����iFa�t糍�\���U`�.�u��W���c�j�4uh�C�e
�E<��$�`���8rk3��1����Wa>]��G�|���:��:��o�w�4���'b&R����17�s�Iz����x1�q.x1A�0�<9�p��(��� �J�>���0��d���Bkv�;К�}Zq�Zm�I��z>r�����i8�U��z�����]�4F���E��w�X��=Ѹ� �Wα�r1:~�x�r�rD@���J�t�XK걈�y]��Q���q`�Gq�#V-Y���ϓg�GO�@�۹_'�g��8@�D�Y\�6[�a�\�8" ��u4R#�<��"5F-QszL�v�F�����(S
�1��N ��Ti�:f��I�?gr�� �2�qEa�[]��U�9�m���[�'��>2�7��@�����a�����p 揹2��p��ǧϞ��~� Nu��9F%�f��k��|���jo�� ��+L5�mf�N��{�lb6y���M/�j��6?[��O��x�e�ג���^A�^!f�2%S�I���k�q �1
�	�X�qZ$�����g/B\���+8��f�P��l�f�
S�@a�@���8F��5(�E��nɍj�j��NsU�v6)���~Ɯa���B��s��(v�
 ���P�72���9:�����XP�à�Dz3��*� N,"�Q��Z�<?YD�y
��K�Ҿ������4��Z%z���v�6��A�_����;�j�,h6ڽ�:��A^��Z�������^g���܄iy��^�Rg����\d��gB�R� ^��e����%Ő��-�DG�\d���Is� ��V�-9�������O�t5#I�KQi������q��ɼ�)�~�Nc��c�M
�I8�@���u�`0��-���mm)���4�j�ݪ�|-H��4Q=�3y�U��g]��+ܭ�Z!�QVC�Y�w;z�n�o��1PE7�z����MʨX��0*�C�����*?����:�XT	�Wd�Fx�?{69���R��
�;1Ƙ��Q+̦�ҭZ-n8�y΋���S�>�\�L���`�˟�#�qQE�E��E$'�[1{-c{u�����T���uN�!d2��y��"�U�H�c��C��֨����t*־C�暑s���~������N�o�;��<n�l��'8`�2.Od
�V��rR>s8z��mqJ�qn�RS�v��_�R�K_�+eU�o!{�b%�̂Z��:k۩���.Իu�Px��7s��e*eNam>l,��7$�F���ڊ�w���y=�#�k,^��L���"�n�䁣p8L��c� ���'q�
��G��<̨�Q*f����8o����Om��{�+��ޮ�c	.�z�Y��<V		�5M��{���fW��Wy�U���G}���emfz����1n.!���/�5�٬i��1�w* }��'���%:I�~AbRE*e,+W�`*'+���ۤ�����y����g�k1�c�p�K��h�z\�D�i@�����j}Q5�{����5����i��֚�,~qM)��V_ΡV4e�����Р����՟���������)5���)�y<��D�Lb.2[�������K�	~F2����ͫ���Z��k�s�u�'���uVg�U3�ó�EYm@����M���f�8������r�����'�)������	��&nO�/���H��w4q}�YPRR#�u�dؤ%���`g���Tf$�{�/Wj�U�����FQ�� -�9����YFW*�s��8��{^M���fSWb�����^�L3wj�����QN�Q���{/�5��_������Y��8�A�����-�A���1{;�5�a�<o4ߐ�*SFW��ت)�۱��T��A(�J*#绸0BWJ�O����u�|�
;�β$V,��v�t����u�X,q�գ>��)}9��2s��\vq�E��ѩ��\�2����UF��0�R.,/�>�U7GoL�����1�^�0c��+�!-�"-(h�c|��(��YÎ�=�T�F��ee��Ɲ�	y�n�N�f5�@����g��$l���ߛ�bL����UH(���7+�7����͋�!�X�U�a��;�1���������:ۥ�V�u����P?���B��g��,f�/��k���<�}���6����RޘK��)lT\n?�sF$~��A���;��������U���jIy������f�LΒ���G-[�(z�щ�HJ��R)栬HB�w0їS�J�i�u�)U�T͐�Hc=|Ѓ	a��@�^�ђuRn��>�D��6��t��I�����ٔ<La�l���Y���.�x\��An���/pJw�Q�V�Z뱺�4��L�t�>�߄��&�F�3a�˔5��*/�S�eNw���\v.��"A���N��S���L���Lt�Pyn��7��U�{�#�}o��PK    �{?�a~�I/  ��  !   lib/Excel/Writer/XLSX/Workbook.pm�}m{G��w~Ec�#� ˒0^0�{�}�'�p􌥑=a4#fF�q~���~�I$��p�#�tWWWWWWWWU�I�,}�qt5�ӝ�ER����߽�y�m^|8����t��,}��cA������>�_��[�����[�?���m�T�Ҩ,�$/�%��d猒.Tvoq��x,�L����y6��<�Iu�Ux�Ϯ�����^��=�����"ߏ^FӨ�:���(��OF�(���9U}����8�"j%� `1�|>�{(0���J�׌AuC�4�D���*����,=��Yu��Y�F�n��X�����Q��*�"U��2*2 Q�gQ1�o/^��'i̿������x:/��;�'���b�.�mT���X���,*ʸ�������D6���EW�<���jY�㼘FK�,x��9X)V)����]қ���4����W�
��*��(O<�o��yo��B<y����V\��u7:��͋W/�n��܇!Y��{=?K������ɧ��q�BL��"�L��[]O?����%'yh>���/�g�R|�u�bz-6Y���"� ?��e�Np�V��Cj�å�ۇ��8�p>��9��w�S����z䖖3����lO�r���]���ye"���b�e7Me&IQVv�@�7U��fA[W�!��jQ��(�K)\��/�M�P��(�E�pr�ط�d2)���E8Qׇ���{������K��KL,8��	[o��-)s�iiZ|wTڬ(4."\wʛE�4ڋ���L.o67�Ҹ��Ņ&yV��7�N6��U�z��g�C�y�1|9Qv�z"弬�)���E#�q>ΊV�*aX��W(�G,�֤HB?mo�S)&�7$��E�**
%�)h2��à�qTE]o��V�*J���o�Y�q�Fu�3�a��uT����?~�T1I;Rh�^<�	u�h�V�=�C���rDIR���.���~$���iO�%�HJX�D|����AՓ�h�,�DOBb�����#H_���(S�u��/�����:�Hq/'?~��1��Ս�ዉ�v���8�F�$(�@��R���4[}��6ttK�i�<�%�A�ޣzG�j���q
Z�!.��(�P�K���h]��
L�����
��R������&�Yz�U��q�B@	2��K��ܣ[7kR]��1l���4�KM�|N,MJ�9�@�O�vS�o+;��h]�3f���C�~�*4�� �a5�}ne�x��*r���j*P����guN|��Z
A��C�>E�a$�"L@�/�)r1,����FP��
Z�hD�q� �R�����8��bX�H��)�k�K.�U|U���gy*3C�もRô�,P�PStAUѹ�J�>���It�#Ic�©�uD~�+h�Dx_��#j��q�j^����!)�Xv]�A6�[�(MAmH@�%��Y5�Tz���)�Q�r6.@0�)0Tu���.��.�Z���ћ�^�߮-=oM���n�$.+��d��6i�(��>�56N�Y$5*]WP��֫E`}m���C/
��7�H6���G��L��Z����^���	r/�����ET"�����8�cԥf��O����|��E�\�1�ɂ"������/G�����jv��~f�uQG��2E�v�r	�D4�2��R���ֻSA�/�����G�-v0'�A��Q�O<i�R�D��@(�rKhKޓ���)d (5�fd=}������ݓ�i@�����a�헺�r
����4����' �X:�|��KX5gE<�*`�˽��E���yӭq6j�b��j:W�������7Q�t��[Df1��UNa[����.JG�y ��4[�K��F�$x��ϰ(m�̶fH��1e�����k���%(bK�����`Li��@��'��%vS;Hx�;�'�{˼���Wn)B��K2���K*�
���Q��qU�~�aG8J
T�
����D���M`UR�/���8��1a�Lg��.	˭�Z\k�l�:�vJ\e�s�ĩqx�dI5$R��ّ�t�O؎8�\���xo�)���A$T�2�4�f���5�v�ϕ��_�����z��X��,[�i����1O����f3�[�y�ǂ�"gm2���m�MT��B�+���V!�7�Y����@�,��(���%J�FM���$��|�d�Kz�,�F�p�fѣ���Y,�sP�`���Q2I�h��AgĈ{H{aeJb�QD0q���
�����p�%�J9�"�>���.%[��8�5�6���?��y!mN�#W��;tl'xLP?T��'
]��F�젥�1�շ�4� y[�a�e޺mڰ;ˣ�H�#:���WIY}����BJ$x�������I��f�m���!���W�;i�8`z:OEBk��]�
�)m����R_�4{ک�e�1J�����ld'/'��Ѽ�ƕg�ȳ��Ӫ��;�<Fa	$�s.����#}潐���]M
}�rP�Z	YR��.�ͣ����_~Ye��u�_���J��ټ�sFG��oQj-7�x��L��C�%"M�Ϳd�@�0�pF\oJ�,���8�P��vG5,L6G7��y"��uu����_� ~�!�A�:��$��^6��yrk��6�x]�Ӣ U
}��g'���+��lL��I�켺�H#	ʂ�e�~T�1����B��E�ⰴR��w�>�A��e������W׍�G�������u��}N�����ޟ���?w޿?ݲ�RjS7��{�D����+�aXu�g[��b�7YTb��M��w�.8Yj<O7�d��g��Zc��
�O�]D%���FecM�@cW�7��0t5�G���m3�n�7��A�B��>>�_'��DF~| ���r��&S�"J��faFIi�T��H����)%»�6�Z��<�Z�=�x�'�?Fx�]W�[/|(�d{���\�-$&�9M�
�
{eW��iQ&����4��' \S	/.
�C� ���?���B�$�i���_���8f�8�$<=A�SL�
��e�c�.��f�y���II�ad��ڻ3g���(l���%�5�-�B��<�'�䩷.5[T��aoI��y}w����(����"��:mh҃�s<�ѸD��m� ��~>�GyA�؀8~��D>늧�2E�1M*��&��O*��O�8,�C��E��l�;��A�nPd�f%6�6vW����s�
�x$?��(ZS������@$��KZ���]����uY��}�+�w{=Ѷ|d�p�J�w�����	�\´�3�ಛ�t8\e�U��ĺ�v��:xR�F���h�٩�eۍL��]����}�t�HV��G�G�J���S���].9����'�'�\]]_���(��4��I��5�Bn韲�}�%w�;����/��;�=��@V��Qm���｀UF[��S��¢�L:���w��r�n�;K籬wO��/#��j�0�~9�'n��Q� 9Z

y,�S�:{�u7��g4�\D���U���OP��W� ��=�ս�
����6��`vi�&v�������R�5ۊ���
�����T�~ɂ�h�4m�.=$�?|@�#ɻ} �u���WT���m�q�]Њ�������0�&/h�sc�}R��1ۓ���n*[>2�c�x��lм`����{g����^MS��\%=�UX+�Y�d�Dl������֞�d"��W8�~uj�,R�U��aڑ�6�%A�9�A��;ѻ�E��+@��=p�N&�U�a�h�~/��[Ô�7b[C�?hD��^#�u�������w�>XD��^ ��h�ÃZ���>lķw�e�q�{��]vЈo�;nv���Xve��ÿ{{~����3�e�q���0p�M��!4ݚ��00���^ _k�l�|��p/4��н�|k����`��k�ou|�V���B�a,�=X]F��[�X�ƭ���Ʋ5~�m��<G첡�ք�n �]�.{?�o�<����k�e�q�g{�@Y{v�e6ҡ�;�{�����iV/7[��e������''����.{?��2��^���z�lh�q�z�B��T64ne�z�ek���q��wo�XVab�򸝺zjo����o���P"�sq[�U��P�yʩ���+�M�t �n�,�z��%q��E������P��z]�c��:���{��m���8�~��gQ�����h�:(`����')o5�t���x��ͅ�4
��e����K	��+���t�����h��柘Ǡ��<�v��Ȩ�	%�/�0���Q��r����}G��N<m��Z���X���oc���9|���޺�6w<���;u��vs�ȫ�i��xЌg�i�[͕6���#A��v�\�q�^����m*yqȂv��V�Kv���ϥ!�g`�h�v��Y~��gk�}�('���.�t��?Z�&�ҧ��q9�)DU̢��ә���?�t�w��oO��g������=��S�V�0�������L1�sjı����ǁ�Չ����������fs��N���3ݪ�f��,�v�pT�L����s��?��iM�s�r�6�R�$U
?�W�R�����I�`4Tg0�0�	W�ƶ�M��wG�q��^9�����Cfk��)y��)� �˸���L���qRA�V��d �D���1���o���9X!A��;}�]������x�!��En\�ߌ�)��ޤQY%H����@;(�A����FfI	�ɧ3<}����y��g˳���0}�=�~KУT�m�?:ޛWD�I�?��7�3gG>�FZ�R�ԟ�e?�lǏ�a��Q��0�_�q>��Qn���!�Y�����u�a��g,���{&�C���:7�ي�I2A�"`8d8�/��9�e(JP��xR�o嶵���������ų���5��x���VW���*�X�,F%"rD�o�L�!'͒�)#�=�n�q+Dw�tIrq��׶�z��証�8�?�#����=�J�+�V)C����@��g֮3i��MA����ֹH���;Y����
1�%ї��lj�HxrH�z!������S\H��7'N.Q��!nP���t]�DU*�};�nc���3&�D������Z '�%�/�kҼ�����,W��$�����C�8w�� Z�MiP��@����&���_�{nNf��H�avM��\i*+X�P����`��턬 ����� �_�
�d�P���R�CQ�-��sHX��@a^�Ty�c�h��%%g�xz����E�Ư
ErĲ�+��9Z�,�P���l9�$A�z[�i>�e�&1Hq���!�� �l���qn{�1��8%�����_\��cJbN����B�K���2�*�����ܡ����0-��+���^����c����lHp��g��<cJY���0�F�c���￴�w�67
��"���@��:���+�����iO��?h����N�Ӷ�W�,Ag?]JQ#+9�S�Q~����Qȿ?����g�w�7T�8p��W�.�N>��w3�@�,Nrl��d�k�tp�_���ɓ���U����w|DDrbh�uh�[�p�Y�c��E|Is��(�MRl�"��z������2�Y���c����*�B�P��@.圅���9���YT:5H���?K���	�8�Jǝ\;%�b�j:R�%�ó�TAUU�m�C�X�Z��͎al�{6�L0	�z�-\�������fƊ�6��#v���{gd��C�~SGA1��vK��Jd�	y�&�q�z���#���7j���s��<�B|G)�vX��nn��4�m��3�Y*n�����j��g��O�+����PY�� oE��7O�>�D�^��9,�g�T�Z�Qq�"���@����4�>��B���pjJ+�����6R?��/@��)��9�p?Kgq����y��S����p�+�� �6�I��T��rV�����<���WYƱ��^[n��d5J���%�y{�s��B�H�q�Df�c�0�j��9smP�<�Z�	-�.�i�QSh����jqAz':���Tf5��=�9�DoD�����.�}��U�Z�O�'ӌkf%�T-�}�8[�5LwKl�:�2Z�y�hG�4(�d���nm�Yh�0߬ҁ$�)�{��騗s�o���=O���vP����Ī�I@5�#�9U�xe��V�0tF�WqnQ�b��[\���V+ߦ�UѰ���F\<b���K�Y�zz��{:�z?���#�뿜W|&׻�~��G/V�7K��4�<tgm+�������'2�0J�C��3�L�.A�m~uj"�Q���Kec�P�����I�\��R%��|���nk��ب�ȶW����W�E���ڈħY����esG�l�if��%��^�@<�ܮ���)U��r���ş�Od�__C���u(�h�vU��s�?R���'䌧�h�x�/���$l`����_Z��a���ߨ�'�*�	,W��jp�7�����Oq׷���4�����Vo��r���7��WƔ�%2�1I�����<A.<W�1��bR���3֍����a2��s4��Xf�E#��p\Mi�@�o��w��P?�e��T���z�%����,�2.O!>�u�,6}�?%������Ȭ=Āꐜ��,@��L���r�T&�K��n�Z��Nv�]Oa�	:ҏ]��H�����a���%��9r�Lh
NtA>-m0��k[l�V�^c)�CW����[�r�*Un�H���sM�`�%�����/46`����4�x�����@�hY�3����+4��؀-~���;�m\ҭcr��+t�r�9�_"E<f�ȼ���N��G���7�-eok��h��\��l�Ej�ӱl�n���I�[UWsȨY�:�?���^x&aItyT��7�Ul���>��t�	 �w�ΣZyvC�N\Cs2�߯>|T��='�X���*ͦ��1a�<�"<�ju��ґ�h�N-�n�:��De�-��A���ID}b_PG��M�1&�/�X\`�E�N��#@#��k����� Ժ�M=/p^.j��՚�O`�h]��Pʤ Hw�8�9�Vkp������~��<��?bX�I��N�������ĳ&�Wܻڌ�*t�wބZ]�sh���=�,��@ka}ySn�%�?�u4(�DP�&�{tM��g�.M�d1��S4��3D��L,��`E�#C�pL
��?�]:����F| ]>y�t�dX]YÆ�)l�J��}�����;���L�O|�.���D-�ƅ����⵺n��fQ
2���5�5���6�"��}�6ěf���I�.��z��.-e|4��P�LU�e����M<ʳqC-���ʓ�V�Ωt�*��d�Yu���ЉKT/onY�В�)�}P���ݶt��$C�T*�8y��w.eݖ:#��CG��^��dҐ�jb��Hf�Aq^���K@�3�ވtL+��}9)�{���Ja+6/*)�|��U�%�0��:Z_J��Π�f�yįz�
+��N�_�1���Xsk����h,��-�|}����Į#�����G����0k}m�4s��[�D��
���r}��VL�r[i1���`�귤�Kx�F��3͈3�6���l`ͳ���<,N���&���7�*��Et�����ݭ�;A�Қ���S�K���4�l�H`(���d�������@l�����ކߞ�6⠛�&�TW^���y�n`�XP%^Ԕ��ɭtL��;~�P���Y��B���l� 9=����3�bJ3tD�>�u��|�z6d�?/�ɐ�����T��l�������#�NW�dU7��]$Ud�}�"I6�v��t�n�-L?Wݖ��DOt�.�mQg|��j��Wy�Ǧ
d�+w��
��8�=U8����>�դ]�Ŷ��V����d���7/b̒�QY�Ł'�(v�bEZ�my�:��U��Tڢ�]ۡ�F�.���t�]"�fnuՁMRu��Tt�M�t�����9��c�w�z-:o���lx�0��& ��Nϰ�����}p���"�9��DW�Uk�����biΐo�p2��8�\�	��YM�F���%P�8���ѦJ�9�#ZЀzWIx��?��j/���������K˟�mL�(el�b}]���Cf
�.��P^�]��̅���O�5�X�O�
�<6����~�^������ߝ;0k��-���W�'3@/F���?��>`�����zGC�Ĩ'S�����𶒄˸6��N����a�o�!ջ�z'-GV�UZr ��d���#~*�v���N@�O�dI3�^��J� �v�_�̼��6t��X��]��"`���ժPjlĽd�����Ր'��y`�^z���c��sa�j�-�eШ�:P�]�b��&(Iy��U�������u##�Ԛz��%�i`i(y��c_kS�Z	\���+i�vh�]O	�*�g�1���M��.�粡2���������&��s�`��|]�tI�)еW��L�ֱˮx3צ��1^ف�Ap�A���!��y\����Nq���ZaZ��7�ń�_�
����;�_&��?a1<?ay@MH�j��Č9s��%�8�o6��E��k���PyRV�k�Y��n����}��" ��Puۢ��[���]��N��J+\���Q���������v�4���Ih��ޚV������1�A̝n��|��j.�1(�-�T�2�����P�Y����H�
�����8����!4�z��^c�#���%�
�(Z���¹�Q�C��[NO�j�:j�h=.��������N4�P�*VH0�Pf���򝪈�e}t�`�z!w-#9+�r�`I �:/�kg�L���_�6�_�vZ;�J9���C�6Ŏ�)�^�C�o���/�Ӕ�r�Hq6�� A�b�A-c�8�H��K�@S�=�]4��iy0����
�(_��[�2�����g����"S�·:���瓣^>{���b&����GG�F���O�R���F@d.W5�?���Fk�}Tm�na��E�Ǌo8�8R6s���}DN����2���u�&�uɞ<�׷5�s!�j����,.�Uy���^�,���lr
���S��y�0��@!Eӑ/����8y��e�� Hy�?E��q���z�E��*C#_�c	G���B��H�����E��Ǐ�)��b}��R͚�.&{f��ި���!(-h�L���<�6����8!n9I|���6>��E�)��%n�P�d�.�q{�)��7{@�簈br��ѱ����̲)�Q�fB��i&�b�Z|����h�܂�,,�͜V����'�o}�&���B��g�jۀh�ł�Aj2_�|S�=b�<�H�)���O�6�W�8��S��������¤��w�98��2��3e��pu�}�y{C��h����@8K2��C-�ߤ�bf���� �3��o���J�r��>�vJl�<���C�܈@�;�-�6�2u��Iz���S�V�J<��.kr���ϯ_��2���%_��]���1)�L��p���U��ّ�KC�GƘ�a�ײ+�G�z���eV�0|�������	:Yۭu�'��zd����V�lJw-�yt�LZ�R#���	Mt�YW �?������� �:S��Yt�0 ���s;�)8$�(OE��~1�}��뿯�g��_�*�^�{��R;��bJ�����]�|F�&� ��;��O?f�d<V��ǐ4؁}�;�m���dJ1l劢�>�m�\2��u�E\�0Q멓[δ�-o�ಣT�7�i�:0`��Q�ۇ�4/C:�խ�q������(/2|@��d�Ԁζ���d����L���2�^�H%���{��O���
���j�V�#�]ŏ0"i%��	F�p�nb��A"̩�Bʷ<�HP�8b��FGۀ����^G��J�����F�A}���r�� ��#��ٳ�R��33p�AkC����T�ژB�i�$>��uۨ�1�>v�P�`CC-��ֻʐ�-P,�sg쎔�n3�G�4�R�;����.��0x�Q�H	�ІmF�x��Ƨ+~��d��Q�3)��A�I1�U���i��qt=�[r���/��>��*+)����`-8�ػ���iL���Z�u��S'�,�2i~<�͘��6	�,&wK*�eSq�'>�����>���,�L��34�X^9)�-D8ى��3U�h����^���=���yC	
����䲟��yh��^O�$�]�����8�AW�����*�K\T�Ë��:�sy��|2AwMY{��1�B3���8�^�x�J7Oy�8Q�(3���4*>��o/�����(���e�uP��HW�ì��}Tg��ל6��3K�[�w��	����+T��{��Q0��{8�{]֔�E�w��55iQ����^p��*X����P�X�ݾ>Z�(+�F/��$M��mE2
&� ��� ��)�/1��F���u����+y�U�����#/�2v̚�H��؍w[)?e{O��eS���ކ���=��D;���ʾ�=�ė��.w�eT�bO|�����yk�.m�S�|�^+���2��8X%gI�T������x��4�0Gz�'�M�^j��TJC��~�����	�|������K⭅@��tٿ$����f%�R���9��iD��EU��wv�I��gqv5Me��n^ت��s0��h�&�u��z���),�~�a�Ճ�#���ES\Q�,|ge�h-O��*��yE�c���"�-����G�{�_���a��Kd\���AN�a�It�-E�V�i�+%�rC3\;]~�o�M�`h���sE4���	�u�*������	g�?��+hi^:���l�W0�����++��9%*�9kx�#jS1���]��S%����U���m�f5���&�Ϊk�k���xb �!a��X&A�j3�4s�o��?����4��7䗰�~F���VJ"b�y�ծr8K趛ҋ���\C��G#�`w0�{`69�l�6�;譇�@L�SP�@Vw�т���	����x(��J�dF�s�§$�t=\���q��K����n��%��[j�91-�q��י��[h"*K'"V��}5Ļ0�K�z�k͒k�e��m2�7C�c����_��ý=p������=�f+̓�ɂ��Wl�(J��q��Uz�R�0�VEK�_�
]��H����ƢU�࿉D-��<�qV;'������@
��d��6��nS�E���PG�ڨ��X-��7���1�h�6\��X*+	B�7AQ�����<�gM3X�Fקnm�&c��l��/����/�9ʴC|��ݻn0�[Vݱ��/�VOּ�q�ꃷp�V��je���q��̶r��(uҼ�c�Z�a�
�L��8�<M����ʯ��ʤ�JC�g�V��n�	̿(C�~"�+d��
��0���g��e|ج*�*���zx�I�V�O��Z%�l4/�/�V�����QC*awVS*�o_���U5LKo*����ƹ(��=�hP"��
��b�$��gmV�Rl��^�=�dT�e>���ǒ��i4��hJ��<�m9�"Q����f�ٟ^ٶ��%� Ku�__`��չ��ӫ!w��Z�I����F����>ޏ��y���+����5X ~��}]Q�hD����)J/hY��k4:5ju_��V���-����.dX���aXm{a#t??�[Y��!��q��2�K�m(/m�1M��Q+�+�R:������,_Nk��yy�t��cuO�z��8�0c뀔9�B��rJ��ҶOQt���&؏#�WZ&�p@�V��px���p��b�Ԡ7x�� PK    �{?���\  �k "   lib/Excel/Writer/XLSX/Worksheet.pm�{{�6�8�?��+��eK���#7n.ۼ'm�$�i�d��ms#�*)�v[�g1 ��4J�=�='�	` ��`.צ�<��Q���8������$�����w~��7�i�,{�Y�E<~�$��ۣ�{{PS�����ɵ����_d�G��a4��Egyt�F��OhP�V�����X$�(�G�l���|�L�yt�.OC�����E���.������`���F�_v:����<�F�������"�����>�ƫY2_��K|� G�����F�\UX$�t�N.h��DMa:��`�Z{���h:Dۋ�p7ڞg���OVE����Ոv��b���%�~�s�������~.ԣ,��˚
�TS�"��wOΰ����t�./>��_�:�ӑ�2-�Q����i���o�����p�`�x~�l)��Vyt����~� ���Tch{�>{�����m{�7��V07B�?����8��h��o�e��8�%��lB���{��<��Yg���\��j��r~�:���O>���]D�iO*���"0��H�Ǹ\�j� {� }��s�?ڽ����wl��.�3���-��2����/�|�O�ıl���u��0�>z��z߭��'�������Ċ��M��\R��_�8͋%נ*7�*j��ؗ��Rwt+Te5OY%�� ��h�(w�*��vo���¯����rɨ�*_��q��/G�ca�/�3�&�i��.���ϧňQF�����b�5P���Я^�I:þ�9�Y�=��AP�j� �a��r��*N���%a��2��O�0FO��$��5�aU�"	�=�/��j��+),���&�X�v38pX��I�*-W������	��:GE��ݒ�ZY��Uq��e�Η#>L�z=+pIn����mӊ��I�N@�h�+�<I楚8� ��$�$y�!Ǜ�g�j��?8��FFX5ݪJ:I�ir�$����b?X%���*�l�����p��l��f��u�L��O�\EO���u�d��K`�-K��r����xq�ėa����r���:���qtv�2K.ט�J����Aƺ���q6ɴ�?إ�8_�q�L}��.���ҳt�< JOZ��)�	s��n�?1�x�ex�J9S���Ȋ)�������C�[�k�����?��v�:PGs����k]���]��aA�r���~M�p��Si�6��e���d�%0&@�j�6���FW*����GW:J�5�bP�;f����?v�ҥ����i��y�h
�K��lU"�Y��T���)^-3%/1��`,�s�-,�R�4��zppׂ���!�6�@]9�?�;e�Oղ�Q�V�Jҥ*yrl���L�ؙ��xJ����ԙTי��v�5v���8pCuҙ�k�p_�'w7y�:"�*�>�ѐj(bT�-�����+i+�S��'���T�Lbt>������C��W_�q��P��j�c���I���#�Vs;o��s��x�䉺��9"n�X�Z��W���̨��8���f*�X�TR��2M����� �J��X�S�Bަ�r�d,P��D[�(�Z5;���j6��6|jn�e��i���@�R��q��~ ��w5���P�]3^u��WSR	�X��֓��4�'�t���W��GxH��j�Y��'�}�}��J��"�����xu����Ax��pU|���������9��uk7]A��*�����]	K����#�բH^.+���7(�ׁI�� ���� i����CU�!D	d�Q��r����]ش�g�}P}y���3snm$�ɋ���M�v(5���)ƃ�Nu՟L��Z�Z.<I�OW��J�� uvPwc2�@�9!�ӢFH�Z0��x��i/�q�*�I/z�̲�	��(�1մZ؞+Fh��WJC�xY(��W3VpB�b�q�-��l
GjE�
���75I%���)�����4�\���4����a�����:��H���n����7�SU9U���`
ة�$Nᢨ��Q@p�  �Ni�H�yi$�ܞ��ё�X��`V��M����2�E$㨨]��婒��B���b_��O���v�eoT�HIs�c��"��E�:ғ�xף�#�?�~5�c�o����[�a@_��9gs+�F�W�[���LcP�زZ�-Ɗ�Wq�����A������n���'-�|�YR#�{��XW]~���TU�7O����
�&�\��?RL^IR���{lAӽ��1E�hoz���3��D*~ˠ�i\���[*W�n� u��Z�������u<�O�Rfh�0ͲIz����$�EA"I����ݠ `�%�ΎQ�A9K�,7���8��'�i��:fq��%�d>�&�QM;��~/�6�ę�TU<]%d��s%�V֜'�7��gj	�Kǌ�����~��g�%�Tg���c��S��y��YQS�x\W���uuP	PG]����i��u&�����/�S�1��4�I&M�zY^^R�U/W�Y�o�%i�+ׂǳ�;#����Z�k�ӷIn�~���I���\Z$c����A�M���Mr�v����>�M��K�Zv%`�%�bk�u��o���ك����V,?����d��	h狨����<;�K�E{b��j����-�����tq�O�5�t�aŎ^�g�Q� 6�^F����������������D�Ζ�3��[%M����A<O����̗�s��ΧǊ�[E�׉&07K�:۳�����1�?_��>�(�VE��m{�
[�J5>VU�����pZtE�\YQy�O�U]�17�t���lԿ��|����`�d�<�����w�7���"�C���h�����cQ���� 4�SQQ�zpU�K���7|���='�F��?a��=�Up��j9�����ƽ���;�Z����ʥߤKB�:�b���4ֿ�ù�/f]@HrP^^=�	*�NQ��t~2M�B]!(��J��aK�|E�	�߅h�0*�R�P��H}$v
Xl�5�"�TZsu����Ũ����cض�adf6�UҵH�L��%jI��c����h矯�8F�KZ�T�g��FF�F|��`.Z���g�m �����U��jpU0J'����@>�Q����l��j�X���Lu���r?0��	Ӝ�F7�͈΋\U��4Q�ȉƏD���+�>b�b�R��2[x��j���v��b5E�#'摇�d(�����f
�n/:|���"��o��y��Ut��R�,h
��ϖ���K�oqp�*�cb����k{����ٵ�زQH$8DOz�$$�Y��R���Rᯙ�Lz(�y�Ϛ����/�۫������Rt�5�⹐:�z��^pMH?�k��D^	�1�W܅U��'s5p�X��E|�[]��q0�����kM̂�P��(߫B �������< ��Vx)'6����I���Qk�T��|%Y��w��m����5�5=es%N/�Q �aIܔ{�&��Ϗ:�@���#�ɅWU�bU�F����ت^v��Ȇ^��Dh�[�@�b;�'HD0��@{�F}e@���7%u$gQ<ƃ\k�!����KZ���kE+{�T�fw�t�� �'X"�L"�K����Z�R�c��O؎haf�K5�do�N�kˡ�# '�r�*��d;�q(�����hz����zG��9 9���S���
m-�|g��������	|ռ(�������u0p���3t&^�~ɍ�k����{zBJ��3j$�к�G4�y��N�$-h4 ��R�=Y��t3T�K�Z�?a��V(�HT�,���̺�X��I�	����ց���z.v��3���ː������S��/��h&���+��#r>?��;���PH,�_b���M�L� {�.Ko���P��P-<��KO�b�	��ٕz�q�бK�U�z-z|,T��'.Z�G���f�!U���A�p�`C	��Cg�%ER5QZ�d��uG��ve�*)�e�A����a[-ԅ���L��I#�77�#���ߤ� 30Z�þ1��%�D��~ɂ��C2`T�Cf�u��@^G�7w?Γ�Wrf)h	���e�`A,�I3G6 �=�����3y��}���d���8=�t�'�)��3Y&���1�4[�`^�P�$Ѕ�%�&��5K�e�$9T��P=��#�!$2
y<[��L���c��K"8����(y�F�,�-<S'�P�"�=y[,oYփ.yï@�V 4O�b������TL�������~���Q|����E��8�20M�${8z�i��kv|������m5�)X-�����3Ā����l��Ts+VF�,F�f��m#�`���3�Ы0�<["���tyϽ�KuWQ���H������EO�Ūy�Ш`��7gq>K��B1�#���}���4>�I��Ŝ6���_d�2�S�1>!KD�D��J�\k�^��������-s`*S�e�q�H��ԕ�0�2�]�)X������lB�]<&gp�.t���0`rF3����߽MOڸ�z��o+�#�-A��M��B�|U����j�:��N�?�1�|�	��!��4e,A�ygO�B/꫱��<z��y7�J�yxˡ����vh�b�v�݆)jP��ȢY@�R��H~�$z�:;��D��#4��w<�ȼ\#�^�+!%������[B�N������;F�۷L�cz�[ꏫ����Q���O���ӶH\Z��T�{3��UXTG��[�w���züF�ߗיJ��3��`����w�+��k��o��[g
50:U����:��K��U��Z7>L��&��Ve؄�c���'��{�He|��� d�S2�npFe���KH��Ӥ�\AWo�� =҅�����kk����:�AT� =y�q]�4�Y
�n�V`?�?�^|�H-&b��]Q��+��OJE�t2��:4`Ӧl�	�R}/��+`�D��妩�7U���sh�c�谼%��]m�1�vƷ?Ȕy[��v@�Ĺ���n#}��(Al�u�1���>�}+&H�@k�)#;����5����D'k��:���]� ����j@#Zo��}��a���5J�n�G`��N��ƍ}�w|�'�<���vԳ#�E�=� ?C7��U:�D��uĎ���[�A����z���e�}4���/�L�֣g��i	��ыZ��`\PT
��F��:�2��фf�H�ג
MkJ����)> �3Z���lo�Ù�����Z&��~`]��ݮթ�w��?��%M޻q��2tTo���Ƃ���-��.��C�r�ֶG7"�1�蛽c����U}f`z�l@éc ؖ�[C��O����T.�#�m�؈r�QS��*1�Ɣ|3ƫ<��>kDe\&�v����;�����M�`��O�ѭ}�p�G���&@Y%��`c�cs��8���5�=FSO4kQ�0�%�]�M�3Y��o'f�|���:�L�'���Px�ʰ��Q��\[�<݆͍�-փf%7��������І�Ĵp��n��~X�Cq7�e��زO�ےѣ���=X��%����5>�:h<�&��q�XK�A���`�]���[�X� ��K��һ����%�C���_��l��ۆ�pBfkn�~�6scFv�UԂ��aٍr�m��|�Fc&�"�p��_|~M�n���B�7��tEc(&6}�4�UQY L��"Wث&L9��,~���P}Kf�%`f��o�Ż��'Vs_<gJz/E�cgbe=|�-�]h�/�r&i��Vd!V�f�r����Z"@���`8�1�ϪM���� ��_�����m�b�K�C���z��<��f�t��D��oU��R�L;�}�к
n�%�#�ڱ��w���ZZv�91����s���P���@"{G���ٮ�Z�A<�5.�7ɼ+��/�5R���;�N�r�Xh0XE��][ i{��c�2�n���_X/���iX$z��g�]���Q�� VhCj��$[A,���ٌ�� YT{��^�S�N�d��Ԯ�L��j�|�{�������s�.^�7Jծ	���ll'y�h�ˎ�E����q)�m���*`Q?TtSς�d1��h=rleyB0�1&�x����o�'�ٌ��R/��फ़�h��[�%��u�0FE"�h��һ�x��� ��~cD���X��M�h���E�"��<ﱧ��_u��\���7���Oy��p'<��5�����������1����Q�x�W�5��QW!�����C���P�]�� ��mB�\-F-V
n��l��Q�S,�ڼ'y�ZT=�!_ٛ��#!��Ԗa�����x �n�Q䄪܉�Q�/%;!nQ�����a4���3Q�E�sE��٭��5���}�M��n�j��q��*�GGq^Y�j�bmZ��7B��gbox��m�����
��C[���^�����Vk���ﯞ��9Q�
)�e��tp2	b�y�N�^����jD��R	� �o�>����vv�\�C?�Z@����i�\pX���&����g��θBnq!��
Zx�m�����t���K��Y[H��ǫ����w��&�A�}��F��P��l+�> p�@��VR�+:�O�����l�T�~�-U��w�Taɋ�	U"0�ҥ�,U����u [�H2_j�>A��H�w���/I_�7"s���C���Ah�($����m]�){��Pw+^� g����@�7�F���
H[�#-E�Z��y�t�n�A�d [iԏ�v�>P���K�	�0���d�G;���M7��N�̤:��t���.��+���0l��"Y�P����!�$�V�4Q����tB�^���ý�؟z,n�O`��q���Q�ӿK��_�'��Sv[T��ߥO�����$���������t@�n�OT�?�1g�ch/~�z�K�li�8V�BUƬ����z�2Y�xRYlp�-~'+��;i�q��P�gّ����+����~E�w���-9�S��O�橧�"�M��u��Kծ�<I�>H���07�%F�1�^:����U�YѦ'i���v�p3B��6U�	�)���zO�����$�ެ:[K�$d���1^cd� �$m�W�6D�����������|}lJ/��w�o|Z_V�^������7���ٜ~+m[Z�#,�]�j��ƽ=�;mɻ����-�,�ϖ�m������K/.��٧�F��O��(�Tt�x5��A��)(�8C�ڬ>�*(�v�Xl�ʡ��Y|Q��D����q>�ZE
W��Մ�s��y�_���B���n�T��Ż{ 0�>�i��h9�{�[�ah�I�#�F�)�ؾ�;�|�_5����S1���kzY7a��R�z�j���@�.G%�u�#=+�Y���z���\-n�D�q����,����yn�&��ׯ�{����O��l*�7�M��,7�nE�U����'�C�v<�1�c��֣'�>�cB'{э��n�E���G��x��Ö����Y�C� rҰ�V\$��]ǉ�y��N�,��Tg ՚C�F�����}ϸV��S��5�v�N�A]���
���"k�������P�����7`�(?�B����1�v�$�BJ1�*��T @�͢^�j�EwC{�+P��U*d%w͍c?�+4 �Ҩ��P֍�.^ͨ�5u����vʨ����SٲO��Cv��ߒ`T�m��h/~�����CA[y�XՉ�G�E���uP��aܚ�4����Ik����Ե:f�����f��|��� <�jn��`�w}�Fv�gq�ߙVEr��Z#h%=�a@K��vq�U?G��d&;���x:�Ύ���o~4E�wJ#��G4 `��#h�lڊ���!�P���U@�8�2�l	��im���9;�~�I8��A��Q�M+ip�Q���nm��e5o1[��&�?��O��bzԁ�0����n��E�=m�LD�+�W��7�5֐�����q�	��t�	8"�X�:�řp�	�����H�Պ7�k`���V3:d�"���FS���n��J�pZN�s�
��i��@+��%X�)vˉd����˃5��Ǌx��(E]?�fu�������7��l�o����~����a�H�T���J哕s���&!h4���+��z7GTQ� �r�F�Q��] U���Atk�(3�?�uUmD�p� ��!�M�����7����:"�Y$h�+���q�Ʊ����'���A�y؟v@9���T"4\��㨥3J
;-�@JVj�<�Z,�ؓ� >._�$��$�@٥����43�JF����7�S�q.��X6�Όr/)�4�I��u<�pZQ�+! F��_�E9̊���U�=��_�B���pA�ˁy�*�ꥨRˍG2ĸ- ��89��g�
��#`�]P7AN�D�:8��}��� �NM%$��G
4��UX	�_m��<u�@q���gX����Ygz�ħ�lܳ}�FQ�*�%�,A!Nʷ���{�b=�G�D�+�4�NE�P]��JS�n'�N>�e�,��o)��$Bm/���V��w�SzF�E���)ؗ�C.+���p�����x�e:m����N�G�WG��O����(8�5�$2�+X,H�@k�g����嗶#k��"�"8�^jq��훷�˳�h�o^j	1=#� ��<�KV_�������o�I2���~�w��	��)^�'ǴƇ��o��K��O���li�!��g5W�0��~�k��O����"̹������>xخ�}Q�8vN�5ڠ75������]�ˣ4���U�2�شX�b���K�_�D���h�8�,~��ٜV6)�)�O���HVP�FS����Q�dqŧxݨ�v�k�f^Ly����5��'���4���6 �:�,�7�1�7�s۩�˒W�Z߈"
���T0�ɖ�-���T�Nd�0���Lr=�G���Y��o�_|�.k&�6��X�[���`c��:|������q�ֶ�.E9���]�%��y_�[�����YP�s���g�]�jF;�M����_ou�������j��j�y~�|���ˇ�k��F���u�Q5:].]�_������gO*8���/�O_/�_/���vv~_��*��t�.��e�W���?���y���"X�g`Uǿ��W��򟝯��������{�|y5�+��~����d��m�������f�8�]4n`���&�\���mOe��Lt:�.&8X~��cs,�#t!i��7*9 �s�\V��<	�'Ng�:�1�2�
����1	�;��:��'d~���
���0m�5���c�C-D��	�{@��[�jQ�1�`	�D'�'�،xJ��4�	Xg%y������: ��yFE�X0�V���Z@��'F&qAw2VY�?FA�ASq<E�!����Y��t�N=��u��VI���*c��
�Gɵ��<#7�:-�x�&�G�Z�"�p��{�va�t�$�s��b�@�v�����`of�1Կ�,��ЯYL�v����ۨ˛]��:��0m
� �����IM6|sB,_���}�,��?��/|G��_�j-V(q��{��y�;���2 ���e@3�.�>��8�$����8%�si�ԑv�[0��\0A�l]������f��=�ܶ'��8Y(�ts�f�T�6;�`�
�V"��`� ��Ƃ@J�q����q�i8����6-�[�d�O��?}���e&���V�+�g���p�W��SH�8Awd�����nnx�j	��UZԼ�jN!3�Y�|5�i�����9��_W�eA��w�� Jo��K9���ԯ^��]�?����]�7�Sh���aN������1���ˍT7Pzb�����S���Z!댺�諯�%$�}�(xȓ���R1v�J����CsR ;��
�@+9��&x��	�;tHҒ���b�y��8G��;�S|�m�}���q��㡄�?��P:�nP��Y��<����xra��(A��H�,��/N�A�* �z�8C��(�eH1X���߅��p��/Fz	��U㯰I��;�^"1��dk�ƃ�,V�+Fe��$�I���G8&Y�蜒�[��Ρ��xR��(u�`;J�;<Wk$����iۮ��8{�_����'�{��s'*�\������g�>�ֶ���j<�>��� :����������P�õ 
s�aԞ��a��!^���f�9M�lu�/(�-h�F6r}��=�K���'�3�d"���#����E@���g��Gf2
�QYB�����0�w�@�6�]�h�FZde��'��X���O�s�f�\���_����v��Ȭ���,�2�jɄ��kP���f�}��ڱm������<��U�$D���z=(W�:b���~�I ��SV$�*�{��	U`s��j�LS�_� 7Γq������1>!=����5��dG���v��*�[f�B5Ɍ����g@�]��-�h ק"�e�Th�H�9���4�T�=5X+��]��spF�ͼ8�5ʹդ�~�R�f8��jC�^�wO�(xx'���(��(�۰����>����?�w���Vvj�7��-�� �o�k�v߻��I/��Q�ۯ�٬�l��'�b��2�-���{����g�9
Ɗ��G�b]��kИbqkw��-ԅW�ǧ@�R$3H���(N���6h���r/���g4�!]��H��~~��罽���$Q~��j>��3��䬣GP>�r/�%��~;z���
LlN��9UA�`��-�����mi�B�БJ�x @�����e�3�Q��s]ǯ���&砈7~Y��q�;ؠ_��8��-h��-�E?r�F���9�<�<���}ɠL(aa�(�@U3YdE$�J�L#g����T<�;�O�i� -<v@�x୎Tdv;���lUp����g0�}2<�r +S�J��.�`�a�@G�I0�T�q�A��lI�|x�����f�7�F"�F4��I�D�V���.[w�1�P�d�����T�`>>0�D:'�J C1M�M�������q�#:B]U̩y�3{؁;�FK�Tސ`F�-�=Ĉg,��>(P�n.����4ë��y� !������ۥ����ig�1�ЬMkA|��8�a���gvx +t1�pb^���g�/;�}����|�q��t���:�;v`̊����
B���|F7������tk?�*a������>�M�pHH����mRB��S�X��!����l� 1�0�%�d>	�եK��T2V�}'[��L䦷�9��ԅx�7��nE��y�߸��,j5kH���H�~���\� ą����3��Zj������Z�����9��ND��.\"&f�𜊾yr���pTN�b�Aa=_�T�c9�%�b���Bk�5S�Fh�!i�KJ����!���t�(�g�Y �7�hEX�k�j.��a�9S�]��HX:q��H
I�-�8�s�fK�:p�6~uX=h��>��袯��u������F����K�΍+_��4��zjm���+��(��قƻ~�*�lCs��R����2ұi���5ʹ#�gnw�k�����CV_��o<�E��Ad7*G�4h����o*g#�6�+D��!L�DT��t&)9���嚬Z@�jϦ':�^r�.�k��\�v���*�����{�k_��|O��D����T��0�������<��{��V�9;U�X:P�i��'q����p�]wb���J'��w<1���791�΀�v���z�R���*�c���I���X�"���C�|s�vAj���J��	��}ݒ9�"�t?q�>�0-e��@������Ee���w���CF��A�x�BQJ1�1Ƽ��a�a�,���>�j��;�ˢ�)�hӫj#qB�p�R�d8��1h��.~#���:�Ϸ�s���_}�bA���룷��̿�F4}��X�8bS���\�`E�w1;ʦ����1$���R`�[m���9Q�
��2�iB*s�O����&B�Mz��yR,2̩f�+�
�
�|ӈg�'㭍�l����a��aNQq��f��"�/�	#C2]�b(B
�/%GY�H���OJ�Q{�����l�R ��pD}�a����C9Ĩ�:�q6[�)(H�9�,3/5�7�CpMc�v@{�Қ�M	���D��IÖPը:A��	ͅ�F��|
p�DU��;;�L�(��hI^q6_�1皦30�X,�)3OQ���Kp��V�?[E��
�B��H�������Z_P|�c���tm,�ҕ!E �~
i�3�|���|'3a5��	��<`� �f"�3��H��@��%�$��0�Gz�-.8*!���-NG�������� �B�iѩ�Z�\@�.i�o+ �e�c�$�[��H����n��2 ��5UH�WZ���fDt�P�;��t��@~|�ĿY�E�h{3��P�;dk��IIOn��U�ꌊ����0҅���p��
io�9_P��2F<��F����е���qT(�{����e��QqrI��u�v�b�;?[LM�&�RM��Nm���-
V��ej� �U%Ї��a�p�ۏ��{$#G��E7���ba�n�����~���vC�Lv�/w^�|����k�(�y����fq^9QĮ�����P���H'N�:�Q���b7`J ���T����,ʖ�Օ�#չ��fU�4)n
��TP���凌�RuΎu���Z�l4ƨp�W�v��K4��s61e%��ۊ>�$����V�^��OX?{�{�L���'Fw�ӻ)�o�MH��X`�V��[ZZ�B��) �8�ꚂB�$j��^���+�IW�u~3f}z�oK@&�=3FjǛc�\��9�h�IQeʎ���p�s�����L	��m�\ۡ;��C[���K�A~ϣF^���mb�l���f�)v���m��ۧ�ퟯz�z�%;'j�u���G�k8��^`�{�f3Z�����,���� Y�& At�+�[�(�GuM]�G�C��M1�[��m��NI�bM��b<�:�%�9
),&��b�W�΄F�F��y����/����օ�ٞͶ'���{��^Q�e���B�N���M��K�Й��?����	���s:q���]�:�K�E��٫����;gS�?�W!����!OC:W�)*	3l8C&Ma	���*]��J	}j�w��;���K�ر�M��X;��v[���՜b�/�7I���	@Ys�ZA$6�`�z8n���&|s�2/��͔%^�W5��*@��q��N�:@
C&����_x�c���X ��[d�z�=ƬG����X$�Xr@d�Z!���*LLxD���I�Rx��]Ȓ����n�tx
p��(��`C�nណ3p��>?Ş8E�'�dtCQ��|R��c88$%Vjc�n^�詍�l�8�"�t	m������h���~;)��A�?��}�9;�L�M��k��!���}!e�F���&�nƚ� ���it���B����I��,�cF�?M�T��P�λ����=���a	.��)�X/�T��UqcG?ze��zI�@i=�`�w˞d�p�8�v^�sw��{��_���:�������� ����@8�Y��u�j����&4�O4�!y ��Є�q�&)xU���O{b]�����d�W/v�!bA���C�86Zd��z�Y(�6)�]^�xPة��ݮ�߆9�����6�
&\�����V��y5y5�ڣ�t������[[_�W�Na��tB���>�!��["��Ԇ�5� �޲TK0~�b�\$�C正l��"B��F�T��9�ݻ*�I��;��R��:�
���Ov=Ш\pq��n��}H��aA���Ug�����E��**8�V���!O�������hx�Py��Lic���D�����;�?��&���#@��!�Ś7=�S ||���$�Y�!gVb)�В�	:~=���DxBӀJV�������&�/lVq�9�sgA�efZ���E���W�����~{_-N����Fۻ���ݦ�ɖɇ��_���cX6u�-Ԫ�izOǫi�.Mɜ�+?g��$����ۏm�ƽr�n-�����PHI����X��<��:�	H���փ���H!D��-���� �o�:~����<���-A}�t�_�bv|\P�aYU`{�"	���wS�&�+h�����+ش��,�F�@�CC�l:�j�o�����.������7���[����Np����Uz@�O}�즆�sh����F�,_!$ +�Yu<��!�իc�:���
b�z�	kwYM	���A��*g�k4�P��q�۪�M�t8�f!rm&#}���y;���W9>^`w�ō����k���zvX��gb��Ed�yt���&
��AJ�����y{�ڎJHz����~�f7 �'J�������M]7�o>�A���;:"�0~�2]Wx��(�".�a�,幺g����!�(y[�tㆽg�qi� � �����!ܘ�e�E��*�~����N&�9n��M(�t/ԝ�l�(�gY� `8џi�9�1*�ͬʛ�?�۱4����*��=qu�m�iHo��Tö�&�>���	W^7��B��4>��V��&O�B0�ZN8'Z�`���1��5���[�}���r�������u��f���@�%^P5�]zm���h-��%B�H��+�^t�r��յ�r\�Y��	8TFp�o42�Q/2��E�������[=}��ə���+N*�B�D_8���kي6;a�o�P]o���{��L�u���^�i��	3M:nÏ�ձ�E��+z���V0j�ԯR�Ng�J�LǥA�����is,y��'
�pv����|��v)��_k^:�x�s�|����tj��o<�^>�����YZo(��F��n��sރ��3�zm�B��b���C���<��5�8�$�b��O�ѝ}��Q���\�D��������/�3򭲚bqJPQ)SB~��R��CՆ����]z������j}��.d��������ib�u���D������`�#�-�cd١XPVv������A�����V��P�'�P�Hà�<�u�gCS�R�N��Ih\)d��o�Z-W��gm�g���9���h��e�K�瀡PXJ��5(�@��G�#{������ۤ
��x���m$��H
c���������6�8T�w�eϐ��U]�L�V�6��і�S���Fz{蝁_�ѐ�\���:��H�:��p!Q"�vLv~��z��;œ,X��L�c�x���踲�S�g�RukK�ڝ�D�+�C�k[��mG����8�u��O�sta�#�-�Ы���,x.�Ͷ�����J�!rJ쌞^�Sҕ�||+`�qq
G��Ӥ0%�>e�:�)���h�	ֻ��"��Oc�����K+�d��K`|t$�fM�DR�m0��_KR�CY_���E�v�>��T��c�O�ؿ�H>yVF<�SV��x�;��,]l�y��;!"��b�枬Â�Y�U��xK�3����n�@�����]!a�EKg�V�}�=|���1�Q��MMڰO|�%�c�Qu�*=e���p�]�9�(�3,١(	���Qhߗ�$!rB��4��h ��"[��$\��d��Q־`��h^�D]�'��<8�Su�%Ԕa���*Ӥ�l�1���a�j^~��Iea��N�Ip��n:�;�,�=�)�i%-h����$�DԿE��s)�(02dG�rIE�Y0esr�?���aYJ� �7B��<ʇ/��w�#�gm_���D�m8*�L|m�E�H��'@�R�;~D=��B�/!��z���pǗA �Ьf[o�61!��&��.� �����b8ݘN�,K�y܈IPJ~ 0��r-'j�sE���Ε���:5��j��fS��E�Y�K�J[vS��&��*lc'��/�vJP	�H0�~Y��`C���/�ܜ�O��5ԗ'�A�FW������,�f��\���׼��@�ߢ����j����ي���BM�-�WzQK��������'0l:M}>`85�)��aØ�O<�G2VR.��4^������O�ak!�r������q�02A��t�	�u<3E��|~�~�@�G��,I�m��m0��.פ�Z,=�K��}��Xr�1GP[zWvmRˮ�n����kV����{�]k�E�`�T��z�q��7�6j�pk�ʽ@,�Շ���U����kO�����B-�\��	���w�x^���BѨ���F��/wÍ��oq���P9�b���i^��A-��ۚ���z#4�[�i�a��ڇ%��lJ�l����u:�i�� ��=��'7����ښ����^23q�/f�h&�������!���b���ܨJL�%� ���p���_�)h��
\��!�4��խ���tO!�SO�x���'�� ;ǐ:�R�ߕ�~�C���.�;2>=
(t!o�ۚU��\V;�˰ "+�D��^µս��v�.�^@X��m����]d4��OP�^d�rw#U�ޡ�^���A�\I�������78����<8=���&�|3]R��Ј �O��]b!L�6���?��O~ۀ&E����]�KQֲhN���J�齭�e�b�to��̾�z]:&���"��<�%�Gh��K��B�
Oj�Md�OK��T�xZ��>�� L5���9_�5�B �ѭ@՜y����Ɛs�y�Up]Ÿ�،��^ֽ3��v�QNu�l�Y����R^�)�=�LR��GDx��ǩ�
���egL/��_v�� {h0���+��,�)h,�ӌ��A��UXa"t 8�����c2��{�g3#�`L�x�,)GO�w��\��˄1�ՠ�*���O�� �ѵg����o��B�(.��@X�Fd4��B� O�D0����pC��%�nf��AI'3�d�L7��5oZ�=���>Tmp�ptI@<:SOU����O����73(�Ȁ�_Gv0�i4����4v�*=��7�.�X�jɎ�֣G��~����b��`���a�sK,0ҟ�S��:���[c�'����]�ccU���V����""�E��Т�*�9�*P��1�,۪�m�g��1\��� ��Cxvc�?����ѱ�H!m��Ĝ�ھ^{�_��]�v��l���3S��7����)'4š� &7W$ܳa�26��fpҧ�,�7Æ����n��_]�&7�Ҟ�����_:m[�����X�0	X ����@��0�1m60�@,h�d�4f�`c�р.��E���-�aZߪ���x�ӄֻs��r���yT[D�8�a�R�T�X)�E���Q�ًڇ{��z�f���	琍��9*�J0p��B$�9����޳�LI�]xD����W ���V�2\����p���wo^n�y�W2.Bs"cd�`B}���*�!�~��9i H�$q��5��s2Td�suBE��P��E�>��Xb!o�2������a�/�������mu�z�X�[1C�y� ������!#8!����w�~�e-8�@���&�=��\�!�C)������5�r�F���G���ـ�=O@0+�=�����svvփ�ֳ�g��ɏ����l����p�����'��g܅�B�@*�'N�8���5���}
9ɒXGQՖdT�	M���`�	PϵZ��ht�w�?��ֱ'؜]��Y�Rd��U��N�;����d�����H���|5�Tq%�o��kC����H���\x��M���.�J��h(�6�_��Va'�'�Q�"sS���7�YCI��mӟ�CP��P��C4�;�N�A}�H���m�q y��f�P��mg	���i潬\6y��>�Z�� K(�n�'�Q��o����O���յ�j<��S0h�����l������=F�XĹo��[�M���K2���8�xMV����c�H<����+UЋ�g���>ߴ`v�fppp2+h�8Z�'xE;[�]̜�2�f��C,q�=(����>?}6���*�W�V�L���	D5Rw�8�;<��E�l4���������$2�c�����]�*�?&�;�iXCg�:�����k8*���.k�Yk����.�X$�;�����8 �Z05c�G ��r�>$��Mk�����/��	����I���-�E�.���_�.�^�͝Ծu�� XL��U�Ǹ5��������?7�3����6�ћ�fLC�#A��B�	�0i���g�"�e�	f� e���s��J�|;�{�9���.L8�,�]���|4�o�u����N�����*�|
��O����I��Upx���dHs�� aX>H��AZ�CH�i:�oS�&X`pj	p���C�@ӻ��R�P����8Л�pz�ⵃ�J�A������t�c���Mk�+Ų_	[Lf�ⵃ`ly�C�|r8=�4�j$����Q�>x����'?=~��[@�������r)���V,��`�JW��PG��=�ݽmb���w�Q�S��)r	漠���R,ң�����u."g��6�c�p�9-�bG��q���E��pTw�=ѡ�7�>���+��j�������?����$�L�L 8yk%��|;#�H9h�̡�EՍ��>��a�d���2E:�$]^�A4��.�x��v����O�|������i��6��M��ع�ry2Y��y7C?�)�,�H�s	��	�A�c4fDY�1f�;SB��m�e⮨��ܟ4�D�Px�C���#Z�����39.1ܫBP<&��w�-տ��-uO#�q����-�c5�/�F�@� 7���>|��7^�_�*<���fD�&Y��,�?��il���U}��6��v�;��Ն�x�b�t�9?1�U,���e�\���kY��R���׀Z��=����,i�OKaܮE����'�6��Z:U��A�i��g���c��G������#��bd.�dp#��)�A�e�	�����������X�Q�p�h��j|ʿBX+����M �����9��{�C���������R	ƃ�*)�ވ�M��bI;�w������n��E�EV��Έ�m���W�Ѧ�&���sc�ŏN�xq�*���R� {�5�D8�����C���=�D��X�F�y5��s��^��$�H��3��9�o�F��;�ǫ��u`��+�����<~���X^���������Q?�o[kju��]�]��(� 8!��5�p��F���2�j����C��oD>�H���A�wF���
�q����*�k��"j��e�/Y�����|�_�sx�����1�b ���X?�D�D�pv�v���_��mF�g͎� �+�f�~�������T������1��ǫ(�9�BQ
	]8u��h�X�7	��3NogUM�!ˎNI�fЊ�T��	B�`�&c���L���EHh�$-8�+Ak@$f��7��8y8����f�x��<�'S��}�,�ty.���y�ݏ��r�6�A���]�&�t}�HrE��.ׁ`��D0��{{p[4Hϓ��<����N�������ہ��	�����$5�1E��R�Q��TA��J4��g;�;�9��-R��EM��<�+���xsVbȥH5�TwLmkg-��f}�-��v� .j� B�#���f?!ᛚ�0A���Q$M�o��p�[��;�N�r���dU��5� k[�0��Tsu��&����c�6��X9�|�,|[�p78�!����u�4悎 M�!�#�����c 8����y�~�W.�I�2m7Dp��` �õ.D�e���X���
͐�E�f�ī{�c�B�P��H�q1�� ܵ-�(J����L���f�{!��T.�S�N�<�RyA�_�Tx.��I�B��ONL L?�/�*��}<���D16 �Ȳ{�v!��o7���̄2ֿ�pi��mG���&��}ʁa�|	��=��� ��|jRMJ��#$�����	�aF��j�
L��TӔ?'���I�U]���U�����q��t톥��YB%��7H���*�8�z`h����ɡ �(Yi�7*��G&Yz_CƤ�+�l��2<��|��H,ޯ�}�O?���N�v�Bti�x�5��a�A�o������^�͙Z���|@څ�9)�\@�d���!�G�2�|���m��M�$jŝ��ƅq\�U8�AZ_zW�.)���pw6�{��4�1����ňդ���,SfV_���Iz�.G�K�J�YEI�Q�F��n8�P�d�F��kb�HO�H�07J��T@�\��k|
�\��O�V2"ɚ���˒ћ�EM'%��C`E��Wj`����L�t�p�s��!`�����ɩ#l�w����>�U�J��`��ul�ܯ�߹��4��N��f����Q���*�d�;y(�lզ]�e�lV����	�ǔ������`�� ���Vu#���SS4�Fk��V��b�7�+��`�#���Vf`FV��+�N����O_</�i������^��%n�x޶�����g7��=��U������My�o��c�g6����,۩)i7�!�8��6У�-�,��9i�"�P����/vP2�I1��r����{02ҵN!�r�c�~��۵5N�*BL��q�e���8?I�ԧC8��C�f�� �s�/n�UD5Z���l�����ڮI�f���y+j􈛞�L�m�W�4�=N��?����%#5�,$&ɥ�]�'�(�"7gP��m�{�ިab�*�L«�hQ�?�%ףi<~3���5�&��#ߕ./j��v%�Z�U�I��$X�bO�V�����I�N gQm�X��U���^@�@!x���[�V��]�U"h��N5o�rG������C����Bo�D!{ZͰ�1�i���g�)5�z�얦�A��ŋSuI���?I;�c18���q��⠶�oz]�ٟ��
�Q�*"�\�=����k�S1������_V�� kG^�K���=ª��AhU{��U���[�/���S��@e�x*��Pe�~�^REl�9:J��<7���]���4@@���F�淋h�c��n
(���%�*4��6L@�$4U.� ����+E�ZL��9/*��"#c�t��!�+��Ev
YoP-��:�b�=�u
�_�Dćʗ!���0�q��v�(9]��u�t�8����p!���#�,��3嘄[P���/���.�r��LdQ1�S �o��+(�oz�8��w9���&�UC�X��}�q'j��mo�D󽽟�<�yoa���b�L����0�%�	2E���E������iH�G1���$a���^Vp&���� �y��sT]Q1\�i��i�}~�Qr"ZCl�E�TM��p)��`)���+K9�f�^D�8zC�����D��Y��M�5�[_�ъa[2��69-_~i[\P���C�#�ҷe�3��+X%����\���B��]�(A'�e�2��d��"�'��*�! ��&�Ua&�2x,���#��&�`O&�Ň$���� ��q	��)M;Q����=�����+�zϵ�Q��3;�|�p"bK�T��ٴ�����"�4����Z��[��������O0W��L�#n�j�~�	3v�mٌn��>��'���5��3fo�O�1�E�Q��G\w�^���Q:��o����˱�xL�N"��9�'�;Έǡ:bM���4��k�}��,-
ԃ�ˍ���;�=���2_ǆT�Œ�5#Z�w���r�E/�\6����D�>y�:!�0- �kI���j�̘�� ��TՈ_����$^�g4���Jw���"@��ؕ!����zYJ{*����іU���1��$գ�߹��e@�(�Ӑ �&Z�.���`fn]�oܕK�#�q��X�L��y�`-�aCyx��/�Eӌ�h4����o
`��sӸ.�m`Ǎ�~Sp�ˣ.7�����7Ӝc~\yh���Ц�&T/�1�N/ :�>��5Z�d�X^����Iw��H�A�KmJ\n�\14� �O��� t�lX���~v]ִ\A4����*9�5U�?�f��GE5�I@�"���l�i�n�4߽����ٶ��_!*�cK���dƍ� �jBx�+j�;j��^������]3*N��Ns1(�T�2�J aU�Y@��Q���@s-�m���TL�`�l��f: ]�>�X������T(c̤e����㊑���z��~�zW�F�7F�vu~m�;��,��1Q��p�xLd����b�c��8^����(>�9��Y�~�S����T�O���r;`�ʧ��P���'�~|�h�GCv Ik4��r�.��w�~�]/�1K���<�������	�n|��Z�A�:�X+�NaC!�>3���ԭ)��C��`O$��/5�\��G��N�&�~�PQ5
u�C�@�8[B)�aq�K�a��� ��ǅ��w!�,�M-��YAb���VE?�6�_�6S������|��@�\��$O]� L���g�x/�"0-D�}y������W�~�j.^q��4-%+1�r^�6����7w�'���P,�y-�ăF��"B��k[q�hݐqa��Q�E(�i<�: �eE�??�&���q�f��F������|G��4c8��Ǉ��g�
��m2w�h���~ 65��x>�Ld�2g"�V4o!c�i|��-AdP�*zw�5��顝B�r���;v��c�=;���F�'�Z�(uc����ƒ��x�zs,c��wC�X$s��W�y�ĵ���M�ƾu��N�G� �;J��~{��&h�//E������
��7cT�]���z���&:6��c�eפ\꓂H!I��Jx!�
U~�,���1�).����;*v�(vtW;e����+St�V��᳕�7��w���wuW��V���	�T���XE�4wU'�%�]St�����BnB`�H%��~�~���S>�ǧ�,�ksZ �P�2����V�����q6�%(xbR��UX���tg��{gn#>�Q^%�b�3��<�R��tQ����u�fq�f��v.c��mIj��1��g���Ev�`{�x��V]�-��x�!g�=Ձ2{�VC�#���^�ӣ��j{�KNl�8\�g���z�{y��r7���s#y����"V�i��1�M'�p�*Ԕ7����mD�B���D������T�jra6�?�a|K
wV���Y�YD�gm	�~_�G�"ε'&��^��c�n��;u��%�Zi^v���B�5C�%^�2Yx��Ne�΀h�.{�i�D��0�P!�����Ldq�$��s�Iʟ'���=�vA4K��m3KdQ�m��/�P�FtW�>r��?81z�2ZM�sF��j����n`�c��1������ò8��K�bc孢ȿ���H�^�`�;ځ���5��v�e��ZRv�!,![�<��C�<j�hP�р��}�n���۾ͦ�3C;$�<3�7���ф�
f�8]��,���j?����Zw�z�oshp�a����\
�A <&�%$O١PM�'��d{F����/A&hՁ\wa��8Y7��dSsG���F�w�f�g�!FI��{d.��K�ce��_RNO` �5�J��-~wR�&��\�W�9c׍.D�Ě����$rE�
��	�h��Y���@p��I�&gE�(��PV%����]�+���(!,¹B�N�-�.	�Et�4_��SH�b���J�K�8�m B Cj�����	x�[�-��Yvv?�~K���rP���%�E�$9^[}Y�$��j��e2�J���4�}<]-������(���n�-�)���j)�~Ͳ�s��P�����A�1-�k�p����r砊�kU/%�͸����BW��1��0E��)p1��a 3��S&��Ŭ�u*u��Eu��;Y׽*������P&��u@��/C[ȍ�u�ɷ��PYl��O���Xy�޶�-�,{�3��a)(�ɘ����:6��YEg�b1�/�M�vՁPA�-$�;�F�y|��Q&��brT����������)�3��!�Mh75���[۽`&U�'j� v��#�Y6I$%����$.����Z�C� }c�3��QRxC�:k��p�m˰ڕ��}��+�~�8�;4|�Dlk�#�� F)�)Jj����Q����5
��[ꤴ�U��Z���W�;�ȝPx5-������a�a\E�����Il0�{y�%�E�����5��ȇ�y�4�Hc-	�����VdU�J�(�S�ZY��ߒIC�����[:��8����րxH[�����j 4��j��-�I�-������@h�[b ���u�,�G��ѳ\���#,�V{Pּ$�h2\c�Lk���0�&uF�3F���5�en�� ��: ��u�AX#�D
1N_�e�� �X#4Yk���<5�ј���VQI�l�����ϔX|�]Z;���FgcN8���9[�5�Y��l�S�QjƳ�եA�V�j���4v� �(%+3�ߣe����:�J��k�w�?�k�{>�id�Q��Cy8s��jHc0�$<�(�J��Ƣ�-g��R9$!����W6��4b����R��k��jj�lU,�ԫ���	Z�'ډM�)�x�E��32"J�P�u��w릫���8dje�*u/e�P�;=xFё�y����a��٭�{�M8���&�����J:�0�vf�7���ځ�֠<b���a6�mE;��ϣ��;έl�����#��h{�37"̽�:3������?_ڬ{Q��Gq�e�1��FT�l����!'�#Ս���LK�%�i/�Z�BQ�G����B�{���e����~צ?���=��c0@
E��52r'/Sk�8��U���߁!�0��$�tc7���0!��	d�dm���^�/��$`� �ȕYg�����d2��
uW+:��'b��H"k�JCޤ
��a%�_<����p@`AG���m�C˟
� �L�qe�k]���x"rC����2�q�j��;�Ƃ+�a�#BR<�;Q�N����~`vXQ�ӂ}�7ª?��.�C���)\l��~\uQh%s�K/�J �L�5�'yi���ƖQ0�RD)�Lh�޽�޺-��}�v�ͺ��.j�����H e�8U�U��'�����h�T^�+��27��K|4�*��E-��XqW� Z���1W���!��b����Ƴ����{5^
��^�mv����bg�SsΚ�N՗$.R���S�F	�q�_��4��*��5g�7�o�XO�������7p��S��s� [��ŕl�v��54�+3�v|��v9��T0����8Ͽ��	�� (�ؚ�*ХGd�H��7�R�l�|� m]�¸L�x'1�|�7#S�cT�[YX8]� �3�[��q���B
�;��+�p6/��/o���׶P��)���o���l<����y]�j��m�u\�j���[�[�ܜ�^y�BC�lFG;��
1�����q��t�P}Q��d@h0W�g�I�@��vY+��=<������"��C��a(���Q�j���x���;��~(v���
 �Ɋwm��*��PfVh�� �4�p��zI���]P��+��5,bk��{�.�� /!�7���2�ϓ|�
,[DE%]l|��@���"˗�|	�:�>+
�tEI��;fG�l��\`6PBu	8z+Y�b�bzZ�j���1Dq�b��?^8�XIg���u1=�{�L��Q��5@E�1���x����P��pO�@��IQ�?�����q ���|# �JI�jF:���w#��,�=cI������)��h!��! @&�#O)A�:�L5 8\gT�8�\Q�[Xl�׃|uƬXT3��`楣4�E���")�?���p��������p�e���Ha�}C�"z���p���N���9.���>?n`��~��%�캾���K��T�H*9��v�܃�ט��Z����]�Q*��
5k6*�e�y�,�|���٪���1�lΜR���G���q���!:�����e����v*~���(Yan~�?��� �v֥ȿ�q.6D�lB3����k�~(d+2U�?~�H�|Tt�Y��[�-�v��@�<ӎp?�H�6<�_m�������6?�)��*�3R��=#W�UA���bOJ��5��˲�����1ο�8Yjz���8[͗��o����y��_r�CO��BO�l�������'ޅtD�܄���@�k�0kM�5p����q�έv����-���78�HwU�#����揾����ʹ_�ˮc:eO[<)�����#�W�?DH���D��t��-k#��6���Qsܶ�>r�#3�"��^�(^H�c�~��?[d�����e���s�
�?��1����[�m8<7��s\S�vo�kb�pW���Z�%Ʀ�|4��I�$+�Q�a�O�OTeZ�2��ᄂnε8���2��.���b�7��%�Q�8�L�n�3��D��q� ���b��2 k�A<d��Y�3��$�Jɸ6�P�ֆ�a Wvp�؛�c%?L0�dzr�蜴��\.J�@-�.�(5)y;T����ʔ/:X�S�w%�@&�`eN�~R�+�qhs4WjZ-<�����o����2��-��8���X#������&��W�5�`O��qV��Lh�:l���L#�BO!�����8���uq�C���(��85����p>�	��~̇.�>UP~}���"U}��v:.���ɰ�?� �������n��e���ۗFY
v��dg��6���n_�25����c�-|�m���(���(p��pN�PZ�RT��Z��P� �����4��C��W rG�t�\y�aH��Z�tDp4Isr!S����h#�����q�tp$8
��C#ŗl��n�		��x>QtrAݛm3`�I�f�2����/G�"V<)�U�7kf�V�QM�����A�b���a�৑싑Ng���&lko��v(���,�$pC(�/�8��<�3� [+R��ٹ�:;r��p^V]!��B[��H���b���h�� q����1;�����V��
�	e/K��A%⎤n#ȁ�4���L�������ZЏXʧ��D�4���8��YQ�W�	?��͒���7��އ��e�ͯ�%�&�J<��w[u��=�aX4�&5:	,׏� ��F�x(/�֖�<@�<u��u��S÷X�ռ�n���:k�p-��!������֕IK�`��lJ;K��CA���\��)3�k���j�Mz�A֓R��u!4˃�!�Q3CC*�D���"Vn���:4���]|��"���Ri�6H���MU���ڻ�"��¯��pE�S*mpð�c��(\��_���Ɲkxk�~8�@�n�ֈ�Q�k)a�+4A��	I�j�� ��AWݯ�Ҡ�']�j A�zCnY�W�PT�K�6��݂�; �S{X�Vܧ�Ʉ;踁�YZ�F���O�е�wi\�]F9GU�Z@�x��'r8l��f��o�`���UY=i��Wǌ����ab�`�q�b*RU��+OQ۸��
�ʸ��ؖ���A��"�Qx�w�!j���d3�
u�B�5�s�pBp�W��t߻f\��o��a(dV�i:��H�����_�l~m���0����P�Փ�m�2|���א����_���/oq�J�>!�XK�>Vў*Z*�ӱc���yTkea�=����y�ǰ@ȥ�y~��߇�F㕺�R~��R@�#,�ZѼQ�'�4��L��2,��ؓ�/���I9�)�M��ՑbfF��hhGm�T��˻�N�ƍY�1E/"��[�B��B|��3�Y7Cf+~q��Vs����"1��ȳ�ɩ�[��m`xFސ
uYp
i�07���xϷy
P�J��%�OBb�}R$H�[�Fq 6Ф84 �� �a���l=&�]�|��E�>��W8�)�tD_����[B�g���h�0O�Y>�6s���q�t	G!a�5,���Р��g���D�♌�_�D���,��펥Ă��>�V1aD��@��9�����1���U��=w�H ��Q��+<�E/L;UΓ3���|�H�f��ج�pWw8���׶����K����S�A��������P�(�vϒڽ�<�m,1ث��n�x����\$�C���84�X�����!�z�0��=����zo(O��A�O:JCd�1��NM�9���(����V41z�3=@�F��q�x�᫼�A��y��Q�9] �=Zڢ��vw��>�J�ӹ��s��Ǽ�붟�1˩�D�tf#�7�+uR �e�I"סK[�u�4�ѡ[����� �)�Z�-�����1���r�l�?%rV�\ne'%&��n�d�Th!L^�&墿�����9�����~�sj��MѼ��j�F7�1���F,���u��e��ʐφ�U<��4DW�ҏ�pRm����MɀJ�_V�_��7�O�^�[T�$O��.��ަ�y����)5+�JC2�k�`Ї��:�8L�b����I~7�A�o�W/���c�]c�:γ�M��q�f��ͣ�W�����<wۂ�c���p�!3��*l����:L�����'�i���~��]������q���eNĠDJ������8ɵk�ȃs�'��8��ƾ�����v��{w{�9���U=F����n@�!J�h�0}駸Ad�[���qޝ3?�ab�c\�;x�'��?h_�`%��wGy��-f�i���lF�n3#W
p*�G��tRA�ק٘<C��,�.�E��Q�}8��zNn���+=M�gJ��r�/����&7��������(P�Ἄ�Ǝp�?7��2��a�v+6%h�`A�j#�j��pJ�Mt�[��t�I��Ly��$�J <yζŘh$%|4j��*���d�H5�t	n��2� �X��SPV�����<��ҡ�x8n���A�K�ʓ�פ����X��k�Xd
T?���rK�Z��*��i�	��#���G���d�������8£�/U�$�X��J����3�s�\�8�~��M�C�#�^����=
s �H
�1��&2�y6ˠ������I�8�����V��a��u��$?������� �8"Qn
�F� �w�zk�;�*�_�Y-\)G�����b('��[�[�h��M��i�2�^�����hޘ��ٹR;3�v���j�S�pe��Lj�)�<T��U�+�d����֏£c왂�Z*^�W5�X�]äC�Dr���}<��N��㜀��"sE2d�j����i{���I<@�}�	��[5��R�@�hEYJF[��#�����k�����C� bD������@���N��ᕩ"<�̳ebh�~L [v��[׼�$N]��4.Dd�A3x��=2�Ed����+��|�q*c�}��I���)�w���L�O(1#����=���B���~���`�����M<�e�Sɫx���q�ͷ�s�y��-���m
#Q+���t�S��Zf�ǅ��y �9-jz���p����10�1�V�gj[ڔ	�0�x�U�	Z1��TXʔp�ƸΑBċ	C��d���0p8�����
���m���
�p��,p���m��h~S-�-��;�<ӏ?&F3�(-��9h�p�I�ϛO� �Ψ��:$ix����r�����$���(>��k��N��K���+���{� K$�=�ܢY0�)V����aBe�/!�3*��9�$`�)�}�{Lь�x�ĕ�j�h�û��Ot�MK'c�ԉ�^����q �3�I��-5�,�ˬ��7�4����݉n�f�Xu�gJ�O��)f��	�IՆ���7� �	@;�8�W��� �U�^��˛�-�#8�����*�%U�"�iÜ��C���kf�@~��|a89R�I��i�$��,��վ5��[��H��Q���Sv���&2ъ�?�
���-�wP%W�_@��ߟ������o�J� t�� ː�LZt��'��/�|�8ߪϦN���ɥ�`�:��H��U	�+���t>EƧ�k�Ne��!É�15��P�8�5 2�3�
N� �i� ��A=���� 0�M�t�N�!Q�&C��5CbP͆����hU��vu�&jS/��	R�&��5dP<��D��I6~�L���0����GS�i�p�/%���AY�쬳Z���z$�AX�o����R^3,�\�Mp��|�;���������?��4�c��P�rI�c�n�n�K����-���!:+�A�z����n�W��m��	A<�
:SS�^�b�K�q�9� #v�Y�C��V�MV�]�A���+���k�yoq���#�����M|���=���<�z�cu�RW�i��� m�V�S�����'ꪖG�|/
��M"�wC��;��e|�i�6j�pprQ_+]\ ��3t�Պ�9�{A1~NŁ��G���
������!�U�e�Ƞ��&i�ݘ��!��4[-�R� �T��Vk`qi�Q�Ɠ�rTXj��}�'SZwx� 	�������5S�#a����	آ ��;�H��dc_)!���+0A�����ܑF�7hDyů�z��]	�D��
����=wE[?y����Ɗ�
C0Au��ܺ�Х���T[wq�	�g.���3�jc����xm����e�qy`AM��z(��,�^Wɂʽ-uF���A�߿�M�Q����K]E\c�J尨܏a�i"����0d�9b���X��'G�P�������b�W4bq���o�-�6�lu4Q �y��B��49��Cr��u����N��l���{�,���j��k��W���
��d(I<PvED��6�äj�| 7� ��x?��oXa;���VhjK�ǳ$�ķJ֣��3W��`AD�kt� ��'D�r 
˱��7-�C(@�ԗN⊘�P�m�ʫ������l�Z���M�R�o"����5��� ��Gι2�����`��;N��l��� �o�k�!�5u�]�y<�(vC̼����7�&fw��2��0�bϡT���J�)Ƣr$��_/�q%˳$�G�xyLeߎ:Υ�����f�:�۞uGu<N�H��w�>��g����"�>��,^DXC��S��H�K\�������X�P�с��-�U��2����7�W1�R�+*:�o���(d��x�/�4�\�����2kA�Z)��;Hc�/=.uepf�6`��섩��*J|�:GZpa�	/b�
�~G�M|��z����ރ�l:����L'���\�B�d��Ƙ��y���o�_����%�+ޙn����eh.�v�L�<�@`�;�ʨJ�|Jgq>'�\�p�t�i?�ӽ���1h`}����JD?�R�UBk�'#^T���.N��y��\Ymا�D՘�� =�/V����3,�4J��:P1kA!��fhU^�˩GΌx(���4�
k;������*u�y����u3���^;�J]��8W�/�i0*E�
	�񀤌�}WX���Ψ�q8�J�� �A�r������sG���_a�"釈�fx� �V?Zp�wKW���Zq4MA,���@4d���%���!S�����g��_�Q�bDc��]�/�}?\�_:-���]*�l�;����Y2�]\\̎�i�jٽ4ڌ�g3���r��������	ă�d4z�������;�_~���PK    �{?l��%c  �*     lib/Math/Cephes.pm�Zms�H�~E�î!� ��-rqv������n�r)J#!K�6��߯_F�=�]�R?����t����q�X���Ǡ��8����ߥ���S��F9�Ql�&�!X�EPD&��5Llb���c����ki`������E��*��Yd
����n���ǧ'�v�����rx�|�n/~�����^��٫U�Yܦˬ�Y��,Z�-��ߖ��}�*��u|Xc*A����n�Q�f���F�e�6齶�-�-���,���"�j�gǀ��]������/���������?8���O����ɧ��'O ��=������_���_N&�Gw��!3��'΄ ���KHF"��e�u�,jT+}P:�������Y0��@�踊���ʚ��7�j���,�GW�ަ�r"E�J���M�.��6]�$��u�"�oE�!�����D�2�*j���W�2�����1�Y��,V1�qt�wK�$5#$�W٦S�4�[c�u&]�HSQ=�eCWE��16�!������t����l�J�@uB�� �����3�(+\#�綬%jCԶu���aֆYf	̮aކy�	��->[X�a]�8�K����b��� ��VW#_Ѧ{C�B�BF&$�� a��h�U0a�e)ݦ�JY�s�|����`���|~������T&x�_U�eY����Qb�"���Q����Gt��5��t���vHL�ra)ݹ��Ć](���a�­v@���v�Qn��od]Q��qp�'�>ycd�id��Fyj��`���BCʾ�ki$f��1Q��F6KVt�xM�tmM�L�1a�B��(^2����%�x�+GcJ�w2v�U܅���ɋ_[��v94��(�{�]Nb���I�cɃF���h��8��&ӽFr1�h�I#��:�<H�9М���j�`SI��*��lZ�,����n�H��c�|�UG��8t�QpUp�[.����*�� ��܈��|�*���"���U�{�hI�����2���ԶV��<Q��t�7��B���4��ɓZ�$��n��W���՞n/5��T�j��%��jH��Px�(���'�m�cW`l7�Y����{���3�5Y�M���zm��n��*/ _�).�8<}?�̆6����$�N!	*m���]��ű�q����� 4�K�掤/��1�!�JB�8�%��?�б{���pOB�aQ�[|�(t��ۓ^���2#�&I��u��I�����>���ϛܕR���]��DDuԃ�3j�K���G���&�@�x�~����*�hHC*�{eu�����zR>?��w��_���acý7_��꾭��ۦ����ήm���g_I�7�aa�U����iscaasj4�B�����8�-VY"U`g7��k7�Z.H�Di���
o���HF�Y��Q�]&�؈�h�u�|����eQA[��M
�Ԏw�g.�lث�)q��C&��y6,*o>�ז��XtŨ���í��3g���l7K�J����i��E�p�8|-	c��	w[,6������nӖ1�������� �8A��"�����v�/�M� :[��5��t��(�lt�Jc��8=�x�,Xo�N~/Up�	$���������Ѷ�Yi�ٚb����2��*�ha�]^��Q��v7��-f�~^��J6bY��Af�ˢl"��Sث>���b �G��/�����6�ԃ�ǃ����M�y�۪/G�MoV���9RX��jP?��wp�?�_\�4�u#9|�+�apyx���V=�,恭��_�s�Z���7�dX���'��)CU�٦76~sqyz>�Tت'��:��V������:٤��'[aQut�q����f��O'��4��r~pv�8���~&��><�sF����!�v	$&���zyDzR����gAD����@��~F�Q|���F>����ء������������R���i󮷎"LG�:V(0��~J��P�Z@9���D�t��!���8��:��3^o2�M|ȣ4ń�]�8�7~�7��ߧ�sj���<<���q�b�<�L��?��� �H��2���K� �>xH 1��-ń�1����P:_PP#*
. �O�̈eF�̈eF�̈eF�̈e|���]2Jg�
�b�y����"� z�슓���H�߁�}��!����|�t>�>��s�SO�ԕOg|�p�������%9c�:m�x&)B���	�AK��k��PF��-�(%̓�C��C=퇒�CO�˜O�Ԟ����	�n<ADɼ��͠c/�!�B���� CvU%Q=t*�L�(&zWM��&�����v'�	�wU���\	�EJ	��:���:\��������\����B`�1T$'\˫�sg�h�QG�=�����ST�:k���<�?���i���Թfͼ͈64sйfɼÈZ�t��8'��K;Y��[7�$���1(A�,%�HN�g*��<�(�6SS�H���L��#x��F$�>"�l$��H|[���K$R�����"B��N�Z��=�40u�Ku�R�.�hOK�ա,�ե��=',�������T��R�����A��Ōz��m�[�8�����8�}��[��0�H*��³�s{
�^Pi#��#�b����n;+of}�Ey����r�˗��Z�ݥV�ŷIs[4}��b���R}P�A���q�N���Wބ��-˳\�@�YN����kj�Z���4���e�&G��Y�)}�=I~�|��Y	rA$�G�Ja@��L a�2��o��)�1F�	PNIZ
��(����r���բ'&���&����@g9�/�>�17 �ٽCVcʘ��mÎ�������1v	;6��c�.�#o�mÎ�����{t�X��Q�[(���Ŝ:mU(-��D�	��4W�� ����D�#Ğ+ݐ+񲵾�tr�ՈB@R�6��w�`����wpq���_9Uw��{�\�1�z� b�o�����G]�8;VгcFN�ƓX�W:�
Q���C��?��G��O
�,���EM�a�Y�r��7�*d�_;>d@���` �'��p88y?��PK    �{?!D  _     lib/Math/Cephes/Matrix.pm�XmO�F��ň���#T���BIB>��QDE�hI6�`o�_x)��ޙ]��NL8Ej?`����y��yv�O�'8l���'[>��h�C���,X�flxî8���T�fS9�Vq��u��;Fp{��w�O�{���/`�u{���V]�
�m���i�е6��^a��I�6�jеrav)l�b
�C�`��y��J.t>O��K��,��{�|��u�YV1���U&;�c���nUm�,�Ж:}��9�<��%QQ2���0b1��4�x�!�T�:$���I㠋̃�MU�q��猈Vљ ��a:V/��Zr�u9=+QI��*�^��gC�@6�.��Uf���!`�>�f� gy2a�n��,�!�  �.�m�B��3�H��)s�KS>�=2o�ȊL(݁ͽ'1�J��V��: O�'��+?`�DĦֽ��A_M��iqw@y��Å$y�=U��R"|��=P�5 !?
|����r���W�E�R��$�����E�DoL������r�#�i�����e��]ST�Q�M���BRA5�А��p��n���4���Z:\+���AE�Ĉ?�y����nj�[X:��'��ا���^���-1t͜�I`�y��e��z���`�q��y��桁9������BV
1�T��.��l��"�Dh��Q~Hs"����/(�ݖ˫�f
�F�&*9�&�[�dR�IW��.�
����4,%aʨ6J"�IW;/\)�J�T���cNʖ�X�aI�.����P���Ю����0L�i��g��WŞ��aɢ&sb5�;ϯɋ��!n��^��d.�*2��ly�<+���瓯��K�$4��� �+Sw�凫�Ͼ��X��)�X-�w�Yc�֧t�L�\�[���z_f�ΗB��U��t�1׍l�k۔Q*)�>�i��lr��rN�F3ߋak�x��F�O����}v�f�.�cQǈ2�nOtu5�.��肢 �#�Z�%�yOܽ��:R[�R���_�-@Ċ7�Y{�0�����)��Lv��M|�Bcf��8d"�}匿y_�G%�Hj��S�WN����`���۽�
f:�r�E�kj:Xz�Y�P'c����m�CA�4Ct?�_�J�_/���k�Hk��Aj]b�V�8��FJq`(^��+�sW��z��|�t�+3w�O�����Ȼ{kȍ]��]�ܣ����d6�5A:�S�ܻ�"�/|Qu�+�W����Ϥ^o��J�g�/���7���MR��ƅ�i~OQɔ�S��0������YU�ͶkY�A���``Y��o�;;�X�?PK    �{?�a�x�  �f     lib/Number/Format.pm�<i[G�����D�-t�'��`�	o@x�d�'$z�%M��s�M~�[U}�!���3]���uw��~�Y�����ǝ�Q<���|V[�{�kox��%^m����?�gٌ}�q�G!����}��f�Ļc7Q|��1�������U��0JE���Q����;�+
F �N��p���C����v��ٳ��$��!����xq臓	�y�~]]]�?��n��X����s�ۻ��_įW��ᦡ�6��(����/�N���/^���?0����������/�?r���bN@��az��]�GY8bY���p�?�_���[���9�?:�;�;=�gk�<�8��9��ck�g����e�NN����~����������דק�l�8���� ���S��^���G��5d�����G�}��?8��4H�۳�����ã��l����`�|���`����	�^}�����;��#0�pާ���<�N��xpV�oE������1-i����d�b�OGǧ @o���5�?�����G�p�C�M�Ο��@@Y�DZZe��ʭ����`1:T��;[�U?1��A��g���Iv�0�g�%�tf[ae?��骀��W�o P�p�*�gQ�S/��9h��r�(��x`�n��T zA�>�m���|pv~t���{��u��g|��9b�4�ou:777�h��	X�y;�'�(D<���t�/~�~������ըDC/��i: X&6�����~�0�*� �V�������k��y}�G�9���xD(�\���M�ר���z����*�0�g^���,��]E��O�p�B�(�i�%^8JX��^�Q\Ġ��}0�#>�^e�Apb,�p�l�6.���p��4��a�<�G�HI��-�X����:P��`� ��o�&9�x���rЂ�_j���b��'UnCތJL��1��ל����],�2�)A��,� `Ay��HHG�k'��
L�+Ә��K0�c�{>²�� ����&�%�'ӔEc�	���.��Q�\L�ӕ�zE	 ��C>�I��d��A�$�n�$�q�
��]lȢY��)�m�m�^�nH��C��(l�R����!�S����2j][���L��4�"B��}y?�rq(h��d�9���t����x�l�/)�Q�t�����2���ۺ|o�;��O� ��'�Y�rY���}ـ3��!P��wqn�t�� �~b�r�,6�x��QR��\Ҥ/sn�"�m!`!5�cP@kW�Z���kS~�z,i�*7�n@L�sXT�ƅ�y��`D.�����2YaX�Ɉ�e��`]	�����\;�i��.��@��co8��l��>���j��`�a2P6ڬ�6��a� �㬡mS��m�����<,�����s�,��$�O$��,���o�.R�G��J<J�������W�c_%868���?��D
��K@�� $�x��Z���Z��gEX˟-��~����|�Ѭ��B��`-'���2��e�m�{�?1���	�hf�rQ�mn�_�){�c�W��M��Bn�'T���"��3/L�$�����1>� a� }b� ������)fs��'m��;�a�"�cWP`օcd�HV,3��gDUr��|��X���QRH s��ˢ�Z���`Ek����8h�Z����}���R<���z�ɓ�ۄ��K�[[���[Y�df�D"!�!��6�A�@b
S���_����	�_�̺� ��Y���?:��`hg�P�q�Sz�k�R'~��_F�:Y ���8�w��0�C�LyL�Fl�Av���� p;�3�b��4��� @4�F{��C~����Ex@LLx
� �a�=,�P��C[פ��#-��zY�;�?RE!��p�O2!o����d�c0�cP+�1{�hv�Y)� gt��DW�a�^Y�݁�Ӟҳ�$�2KX�D*����`��������/�ă�zB�a!�\1O ,rp,l�K1��8���q��,�!��V��������-��A�[�tCq��l�O�Nꬃ}���{�cv����0���5v��u�"8��r��Ed8��k�2Wh�@ a��H�g7�o�-uB�VI�
�����"'�L���y�!��d������)�P�!�r) B�5��&dF�+|8�#���N�[Mm7�6B�� ������z�F�;�K��Yb^�$�޻+Gfb�����x#9�|'�_��Q�~{�Q�Q��f�r�;�?~x.��7�\�:�s�;�?�頨��Q�N��Z;��� �ȼ@����
�Ē�v�������?��P��4���Q\b=O�w�:����Ea"�.r�>������WS���q6�9�G���kg�P���5��l�=h�Kj�z��3�����u7��uO,�5haCto����-	�p�jP�ƕ"�Рg]���˃)���v$�7(�LQD�+�(���AM��*�����H��ѓ'��
�
ZNCfYB����_E��vL����������ܡ��Hfأm���`�6�����2!}����qbk����((�VO��x:�j#��<o%��DĖ�bi��Px��-�/o���� ��DO9�6ow�'i�V�@f�&<��4h2bV�55�r�@ƍ;��?bԣ����_7�5�8�3���J�C�&W�,D\3�������	�åC��_=r��!s�T5T!W�����������x�O�����Ok+(��b�"q��*�^��'�R���K	8Ǆ�*��y(�R&���ʦ|#��.�h���x-E�Uk՜���H��<a"��= �PD�C4(��f�yz'�� �<�`@�v�D����NCXh�����B�'",Е|��-�,�G�B;
>
)���v�ar�H��ȶ�+a�g�F�C�)���Sa _��>�|$�h�E���/�Q0��
"�{T������Ri����P�N�
��[���8�W��ƀ�N0��uѭY+7er+�yWIC"����h�S9�xbϱ���@����6{�� � ǰJ��c$#5�hH}�/�9D��g�=��{F|�@,��Et����8�qY"�8n ��D�kP��:�?�*��?�T�X�!�maGd��H~����"��:.�\�u�+%���V{)#9�h����8a�R����`��#���Y�f	e��mp�r�We�g�]ǳX8l�0�$XD#��T����ЏZ֮)[ڄ��{�v��On�
C���t=���B栴���/�1�>X/y�k���K��yȐ�6��E�WN/�GQ�֝�uȱD�6H=rmJ�����Ta=���6Vܨ�4��"u�	h]2���A�TX����ybD��&'����u�h����r���i�7~{�����is��w̫�M�S�.FhT�Q�2B���L�A)���sa+��uK��LE�L*W������3����}*�w�Roz?J��As<x��Nd�^��'�'	,I�m���U�ei4�&>W�`�a���#�*����*���9�Ѷ�3��VlH�Bj2L�� J<�K�Q�
{l8�bo�b���N�ۡ�46�p�N�mͧ=^���߃(�G������zA��\߃�SjȺ��T%��"��-����ۆmF�5MrT�9�(`ƌۀ�,��tR���5��߀�s��H�PX��Iazi�-���E�#S�����ʈ$�)�%Qaq���V�Ua��7�g0�Al��7���l���V���T���#юB��iDO� ?L8��V����=[U�'!Rv�$��i���f���6�.���9YQ�7)0a㐸��fI�������]��t�j��S8�¨z]K�~4������i#QZD�·��6�2-��-xU�I���	�"�eo� k�5�ҔvsM�ז�Cѐ�7������ O��Jj>�#+�8��Lpaz���X^�AH�s�1���A�N�x��$V�Xs�iRU0T������	��u%�����Q7�V�~�=x�����̢([yD,�\�~
�K��͊]��o�B$��ր@��6��Q���6$SB T:�֠\3J��5��Y���֙�EIe��+,�1I��kQ��(}��b_������mK��Nk-� &�l��v�Il$K��&��sy�.���u��9����0�������ɻ�?��KD���_t,I7\P�cY�$_ZCc�Px�'NC�qU�K�~|�wg~��c+I�S����<�J�#ÄMT6�(W�����UW��>E���1ҥF�a4�C'�tQ�6h[$[�����!����l�_�bΩܤ�'1Z�T������0�&ytR��fqB`O��'z�q��ű��h�=�T�c��a�j�"c�c��U1U>Y��ZK��bmg�R{�]Vcڳ�TJ�
�R�v��/Mc���M���V��|ib;tM��Go��<�o�Z�1E:�W�S���L,�ȵ���\�\>��ZŒ�G��W1;b��~�cZ���eD��������˃&>1�� y��m�m����vH|��?(�q�R}*a�3��;J8r	��kvXJ��|h
�fws�P��0c��a�anX�|ش�7�j��!���t�V���wU��������Y��s�\Ҷ1nb$M20-�#�K�-,��0]_�KL( ��8��X�
�����6�#�P-� ��)ocW+��Ϙ}PMC0�Z�[���,�^�Ö@�̉a���U�e�d�G*�+��cZ>F_���?�M�S�%EԐN5�^�7�@;��hH"J��j�;�Hs-�Ul�1�1�� ꬞�<!>�+�v�Q���N�S5fUi-�e~�M%ֻ�y����9ְ$����^o)p�*���X�MBTGi���Xׯ�M��.����=-�n�:�uo�v�Sݨ�I}�S^J@\�v}i��%��)wc�޶����$����g ��.բQ1s��?�9��b��v1����A-Db`�7}���ja��AGcOm�p�ߥ�&������6��~\F��t զ��7�(�`��d�s�ǟ��D�W��n��9ѩv�?(���$
�T��~�l]�'�H��iey�����<-���b�B�:A�2 F�d*���└*d��sN�����[��6O����3\�G�G��y��m�a���o��K�b�hY�m44��j[K��(	��Z���1%ټ�w��Y�'��۽���[u6����\fs&P/
��=Q�f�@�`���{�jM�Ǯi��5��&�V�}E㧔p�[>sj�V
`$���_��{���+�nR|:��*��&>P��p|�k;e�* �e-�yt�E�
!j��Y�<�6d�p��J����<ę�k��rGv�G�.Y�AQ,r� b��N�� [�l���z�W
>D�Ⱥ=G[�f'���mc�,^j�|[3XWMs����0�Htqf������%1��>g����ik�,r˙�9�P?�̝yぉ�̜)ݲ�Kܤ�Σ�]��*�"�r�n���lI*�~�e�XM��|��6�3K���������k�B.��]'�K>r��hN�e+r_u��=��=��x���U���as�S��<�R� �P�1����uD.8� ��9$Er��x�Utv�n#�J_��unZ���`���Y�W�m���'���N����=6Ψ��{	7��Ћ�f3gK1�Z���a��k�|d�o4i�a-	o��7x����C�]g���mZ#�ǂ�T��m��r��՝\?���YWvAI��4���TUӗ�1�H�`�x�|Ҫ�̢��+�5ȀF>>���9l���`?����۱���N�}>l|��n�h�Z��yѪ�ie��c�\�2�_Y����,�*7ƈ���}DC���m�0D��s�V�<lH&~�ś�h؟Ű>s�|(�gZ��@�)#�ؾ�@ܠ�1���u�^"�ne�;����i�>H�>� ي�n��H�%Ѩ�}��Su�^W\�g����X���
	޲�,�5�O��wt�)a�뤀�������!�ݐ���5�i�n��)��G+�f&����ц+R&o{GC��Z���tkSZh�Cqt+z��I�D�WǍXJ��i�	ϙ(��n�`l���`Dh�i��?86TǪ3��m��%��$�u�V�Z}�D}x�=c-��l��ʦD���Zm���I�ꥑ�Ƚ�.�'���� U��>��Ӏ<N���q�<
'*��8��Yj�~R�K8?C��1#|����'�L�:]Gܺ�b����i�콤r�xl�sw����q6׮�(���Yu���a��ϥ�g���a������.�~}��H��ygPh��M����B��l֜�I���r���X���L��{�%i��^ �t���nG�TPϵ�b#�� }�E�� �b䜊&0���$���bC�u���D4j�Zк2G%�/n(�S����B]���>uZ�g8���&�?Yn�P���,uoA�z�G��>R����P��hG�ǘB�ɇ��F�+���o-M)c�ŗ�/��Kf�p��Ŧ"���W[՛Z~�����ٹ�)�q���	�L%�M�W�':�K	�剱��s�ۂ�#/�\&O�&Z���g�PG��M���Xׄf���
��VQ2��SX���b�h�E�Σ�OV^U0�p�`u���8�1� J
ѣ��1�(�'����6-�ѳ�y�u���Q�kE��|�d��^���b=��^q�S`�Ӛ7|ѳN�ľ�VY+w��+VLh���3��1�/�Mx�&��В��3�n!Z�e�e�b{���CC����b���7�y�qX/�2��8���v�"�@K]�蜘�܇w���x��5ݫ�i��Ӯ�q=-���_K����}YA�6_"�'���%��X��	�8qMr=�.B��U�X��L��5}��+|ǥ���ae4��PK    �{?ү�6h"  �w     lib/PAR/Dist.pm�=kw�F���_1����%��c�ʱo�l}6��8۴U�C���Z"���:��~̛�d��{��s}�H�`0`0��I�Dl�5�����y�ͦ��,^����>��k��=�vv�ƿ�E�u}��YĎ>�Ҭ�2^zd9����ut����+����!{r����S���'k=;�����
����|��-�t$@�e��q��8ao^?�"M7�uCT�8{�_� ��&�_��,��)N�"�L��<����<_��xt%�Qv��Y4M/#$�p�4*��DYPD>5����貤��s�$�F�f�&E ��gqdq�SU�"���ܧA6CC�fip��\O�~��,����|~f��]7�3O|��΂b�������g�PA�W�N��� ��ߣWr����(>8z���4q
�T8P�5JS�y����P_r��E<D!���I�)�jꨀ�Z��5=-ٗ/�s	�0�'�~C��Ò�h�t�hr/8�]� K���(��`�	QT��ـ��Q�Y�G�I������� �	�\"�z0dM�{��� �n�`�CΉ�Yk�\����^x���W�����0�8�r�����$$iv�0S&Q��nȚ������X���,J���W�ϏޞvX�ٱFb�r  a�m�f,�#��4Q��
�yW�I�%���8����>p3tN��$�\Ȟ�L`7�A���o�a�ݰ͂$d�y>f�`Lq��t+:�a���X�s�7��W�,N
�L�k'nc�9H��Ɔ��6�]�@^��9�5���l���:|y�"��SH@���l��,K9��v���F�mx���	�h\L'�������$��&�`�~?L��i��yq
��ӗ/�Z(�� ���}�Q<ʠ�,φ��|��Ş3���j��4R���|\�#��?ع����b��8���Gz�h>9p�Fi�bk���������|����4(�c��q���굿��^N��&�O�@�$>x�q��6�l;�!���8�����yЦ�c:���%���~��⭥לǋ1sI��P��}D���g�4�_\�`�ˀ�4֬V�%	kϪ����	tf-ޖ_�_C.
~�o���v-���Aa�
��[Q��o����^�w~ɼQ�P�]���4��D�;��~�_�����@��lm� ��|OT�P�
�v��"�U}ſI��T_~e�W3{���eZ�c��^�[j�Ը�|��!��M�+i.�<�����G8��5P�\��+�³㷧������ۭ���&�͈���K���`bEw�8ZȬ��mf�[���P �<E�O�Z���Q����j�1��`�H`��Tn,t�j�<(�Q-;���+
�jDK�|%%��:|Z6�Zv��l��<A�|�]�8�=���L�7�( ��,رRJ��R{3z1��)��p�P!@�ee���,F(P��y^��3�|�B��[p@3�Hg� dּ�4��,*�Y"�:c�$���	;Y
�U�lM��>�X�+��¾XFqr!�a�#��6`pix�5:|���`��. �� p*Re)���[�g���J�	x��IyQ}�v�~qk�W �!7��NC�k`�^���^�p��+X%��w�r��t�\$�"i`���T ���.��:l��o����X�KΕ4�q~�g�CQg����3@��LH}@�"?��3�YdTpH�S��-�����Q֎h�\6R�u��s��"��v�xe�9\a>�+Se ���4�]���ߑж�1%��-U#]��� A��Xy��ͦ���&F��f�z֡Ƨk��j���k}b�˷?���{��L���`��iK����Y*�Y>yq�z4i7����x;'�c4�L��B�-�,��"���EN0�A���.K�C�}"��f�ڛix-���U�U��%��^��r�1��A��~~���_d�l���=�/�5-E+�.�"W���J�*-Wa���7/nK������Z5��6���K�����|��Ȝ �J}����$d��*��dd���#JP���~�[�"�N{�L�H�WWw}s2(�V�d���?.�8�ѫ�����X��������񫷧�/^�'�_�.�8���P֘Y �׮[)L0���x��j�o1�%@��B�i�߹L�\:LG�B}P����������D.Ǝ\�������Q��᠒'[���x�־/�b��v��NWٹ�laK����18����xV8u1ã�Ż"����˟4%`�F��0t�'���zwm_�̩�iy�?���HT�X���x����Çm�F�A����������<�m+��1�w�!f�K�Z�S��䐂�r�Ƥ׮-o�[c<�7��� ��`��SQ?W3�~M��륱r���u˧�jË�r�.���ݹ.�,����A��"�R���6�
��g���~_�Nѥ�B�r������8C����ž�&[�|{r�����}�����u�p`��E�#A�y�v�c�t����Z](wR�{�]�Jm�6C�o�����i�E������J��f���$;�ǜ\TP3�|R0s011н����Jk����vXi�����|La�3��(��hX�`W��1��x�k'�$!X�����F ���$��-����� ����=v:�3�4�Bl��~�#���1� S�� \�Zp
�y����!��r���0%�]�
��������l�гl
S	���}����s>�GƖ�X�Jo�;��ET�Ev���<�g`�3�0����fq�me�H�}&�u	qX�K�5I.�P�66��vǬ��疕�T<�u5��� �cW��m��u֪>�]a��TA���߾�}]�RKd=��R��@/Q9} m��˝����g���>H�Mgŕ�Zb����Z*{mK��(��:�t�$��K��>ϖ^�M��v�F���3�������2��R��Fl��:xl���6�uv���@s`)
V#!��DX�G �V��f}G$�j�o��Ʊ4ܖ-P���<}�+�h�b���O�U�z4	.��%��6p�%���,1u4(p&�������h�lI���Fu%H�&>S���˩�n�4t�H�[�9�X_�ˊ� �˛PI�Y���ͨb���Z\�6��lx#i c�R��Z��_09�ҨE��N�-v�*���[`��_�����#���4� �GYQ22���R��b.�}Ȁ)�r��dNV?�����_݇"x�2#�$b���:+��"j{�[�b6�0��<��iƔ�	X��%:ٲ.H ���3���j�	@���0/�QG�pA�d�s�^W-إ���Q���J�Zᧃ�8�M��.�S�3MA˺�X����H1iJ���llL5�a�th�L�k�=��'��|����%��J�y��`��r�6��:8XcG��r����ӓQ��'�J�Os�0h�ȹ�^t��"Դ�CwTل5�βymo��]���}�%�H����F���w9sdj��Y���f>V����k+���ނ��\�Fkm�� ��?�j�3����hH����:<}wr���K�a��{�sU�����2�*�nO�0�����ڵ��z�Ĕ��D���r��QLM�&�a>� �\�8K�J�M���V����(�Yᶷ�8pf����	M�<��]�iӽ�5�dӸ?��%�+�����k�qT%�
BL��_�s魏�!J�����0� G-�#Y���6���$������)�⛝(OOE��Ǩ֤SW��)�`���0 ��'t�ږ����D�hz�+�$�O	/��SSE���
�p!e+@;z�KkjGO�U�
�'jwAnuoA��j��K9�3e��׎..���*]�gw
+Z��l
(��_��o6�74L�Ϸ��}��zL�k"�,�c�eK�+.؄i���V9��&'�lVT1��c����@��|�>���X?��@�s�L�<aψ4�E� S�y0� �Qs���|ʜEQ�У���4�t��و��
��,���J�Ep�$�8A�C0>�Ўrn�Ͳ�dJ)jÿB�p<	Gڲ�o�9A{��I���I��Ւ��8��%�ꘕjs'J���c�/Ƨ0W&��DG����J�w�	�aD�K��T1�&kp�A����;k�d�L�X�<.�(i\��פT��c�M𐕓p���1~�4���t��s|^�жK�@��83\��a�]��j��+�3S���Ҭ�c^d�!�G
Ɯ��%�W?��0o�N��	Չ�]��<B�$T"a{�n�0�a�x,��+RXT�fyaZW>�4�3�D���#YKV�L��+��װ������?����*S�fvw*uZ#�U�+����Љ3+ͧ*���5DZ���R��&�r���s�C5yT��@P�zi�UX� �s���Z���atR�{�P�~>A펋�\����r�$�ȣu���aVjd���������ֲ]���z<�H��jIF[E�D�y��L�J��	�䈔0J/bT.�H@=�"1.c�Ed� �W�t��	9���x~�~�r��L���ʳ�iW4��S���DY��ZYS�}�2f��=�~�!�
v<����|:#P�b���qw�G�r�8w��Phvr���Gє;j¿�/Lt/�1Z}�\	�Y���b�f+��ѶuA����t6�������s�YH�`S�|j�	�����79�r�q�h�j&�)9�����'��TA�������Am�B�Os��P�(�0qK�+i������/`e��ZX�o��Tǿcw�QI���|�H���2�h+>���IGZ�jC^��BI
e���AE��Fe�I����
j�6�J�.�E�|m5�:��� �^`�N҄b�"����	<g�v�;���Vn��sL��`L�TU�(���O0�)��Ծ�݇�����%Xܐ��t��	.b��Qf��8u��)!�F�h��e��s*�Hȧ�)�I|�(�����t<���OW����0~�<�
��t
z,�U�"%,��yjhi��*P�n�N(����u�t]K3�u�����/����u��V�,��+�t��ߝ�q����E��S�ゔ����y�����]�l�X�\�S���ҍ�A9���"H��w#p����N�l�nΠ��ʉ���@�mcົ4����<��#���D�S㿷>����BØ�,|v|r�����O����2<�>Ϣ�f��8蹏�0���/x�A��+��?Q��FK�t���;dЂ�T�����]8���_z��u��_�
����}�f�����Z���:�|u���j�jQv]��V��a������,~��Y2:�r��6�c/VGa��둭,$t ����#vD�j��`iF8落�[g�&�<��f�* S�ܼG�80'����ԞS��"
R�I�F����5��2��>��*a�w�hKi��>#9��ɮ����,�U��8��^�9v�M�~��o� �=�˖��-��>۬��g4��<eFW$�%S^�W�C�l����"�8����gd ��!v��O��V����?ǳڎ� �[`݃$Zhڹ�y{���O׾����+��AڏGxߞ>;:9��##�.#z��7���J��Y�L*��i�3�A芳��6����ϔ�R^���2����=E�v`n6iTz�����\�iɳ`x!�>(R:��5���x���)�5��)0�MR��!6ϫ:T�b�4w�����3Q�.�[�X�� �5ͮ�Ziˍ�m����x�	�u��<�UU{U��^"-�u�_'�\B�0"�=I�8��@!���_������"U6��_r>-\�W7kw��T�I�H��̫��SRM��C��I�����"L���R^��~BLz�9�Ds�Vq����6�xJB ND��-��&s�邮��F���� ��O�\T�1(�k�z��%�ء7M��H}��3��xb����D:����jN�:��DL;阼Z8xѡ}�,��Kyޝ��Bx���%��	p~�Pe�n���s���8L���;X��4B8r��7�p�9� �R@+iʚ<���Om���Qq"Ӻ� �NA,���ޠg�F��)��tU�k"6�>D�QЉ[N��t0&1�Wʘ�Z�K�a�+I�&��<=j�H}���{��q���Ngk�|p�R��e���a����߅J�A�=��R�j�5�Ȍ��#��yNt�&�.Czh��y`�#���
��|�>ܵ�Zw�V�^��P� ���ݎ�Y��� a�"��T�|�&jN��ď�&�l��Yl��Q���_�6i��_y�F}&�34^��tě�ȑ��������vE���F�.$
��<��ڞraCE%���t9h�4����5�V) /~|��θ�(���(O�ӣ�o�u����'�^l�Wd2�R_J��eK�\�:�!�k���m���<r�w��ٹ��)B6l���=|(�_��Fe�񶁏�Y��@��+fʇ�������vo�ؠ���qQ̠�b�𰲗f�=��{gW�`^��,��ao�u�׺�}p�3.�P�e�18��g�C��]�n�.啉C�k^�y��_C�ii��eѵ/�P�@J�6�Jq�����B@Ľ����<0'�Mt�����	��y�Oqj�G�\K�����)�<��vR���l�����WF�����^L������K�"�����J�V�`�j����>
��vQ~��\�1�VǊs�.Rgp?_��`}}Z�PZ��^hH���ex�jg���
4�nB��nنJw�̸��6a����t���V�7�X�����7y��*��Զ�N�l������:�E��Jk��"�mW�Pn��@ʫ0^O ����V&k:�^�d5gcP1%r���~ئ��;����Krb���_!�t:F'Ev��AIȿJ�Fә�ʉ��QԺ;�����\�f�lª���D
	R��"��k4Ӗ,F�&c��Ċi�/��I��{`�!���h�9�P�e]�Y�MZ�O�w�۞�(Ã����_�(��ȃ\%�'���������������[�4l��Ư��������R%qO��\��op2���Sֻ|�
*܆}�h?�2��+�|���ˮ63c�A!��Kd��7�ߦ�Q#�a_����:�x,u��	�O.;�	w�Z�K$P\�E�Q]n��i-�m����)���({��V�pt�-�S��(�P���r&j��A�A����Η�/b���Q�X��(L��U���3d��7�]I��P^?��C�P�'�&���8�Ad3.���	�c��Ow�;]�����Ɔ
��a�����Y�J-|��G�K�\��	���ź�	�D�d��+�"���I|û�a�ԝj�ҨROv��|/w(˿��G�*�N���W��^|��P<j"T�%�p,�!)�5�Z�m놄^��ʶZ *��T�tM:�	\ɨ�Y_�<c

Ϟ#�5b�,H!�6��P$X���n�▸��;o�t5a ˎ�������7H��[뉰�A��BZ���0J��h#����-���2F���u��^+�eK�j�ȿ,��o�d��Bl�W���i�����#�U��U�5��!�[C�k�jo�Sz�[q�k嗎n����S?�W�~Ȋ��TT�g���R����p٪�0�C�����<4髀v��@\i�}wu(R�)�m:�J���cp���#�>ڛ�������ş�٘̇n�d���Fs����>��Pg��9�������$�����ՌO��
�����Z�ʯ�
h��W�i�?!�&3M/������Ǎ��F�m��E���Ef�p�KK����p:�Ǟ�MǊ?�\��˗݃ipu���ĺT"t�꘨+��J�~��G�%:&<�y�ò��9f�>8��������")��H8GSC7�� 6��#���� ^i�y��e����QcKT���1
�A<�ӡ���vM���UE�k���:O�t�<�ğ� ������3����]�=[=�E�Eb�<%ٖ7pfA��Ҕ��'�.��7�(�ŒW��z�B�!���fS�����yZ�����8�[*�|���]���@T�� !�cg�/�DN�����X�î�7h�����Ĩя���0����v�iϕ�A��~��S��#@}�b/A�-$���ƿ��<����W0	ՙ#\T��kԟ?�Mʙ@�M9�؞a�n��h���ھ)"PJY���9���>{G?y�T���0�t\;Jn���(�$�J^��Z�I*~����F4X`������ֵ8����������gG���ǃjr��♟W�z���JGǮ���y�j�V~�+ң8ȓ12^�,Ng)�r�D��*<�C��Ɔ6���9�	��C��4�t/Ҍ�n�PfiD=�j��j0�@�8R�g�W4wP�B��t���t�O�GL��[uϧEo�$���*�ݵ��-�ހˮe�m���1*83U�oA7rM��!O����}G'<���~		�:h�����"=kOlk��Qr�o��{��$��������}�Gs~�;☕9���:Àp�P�ɷ��d���M�����ᾖ��lZ"�s2�d���yWzj��4 mʳ��{�^!@�A*j�ې��0�����k�PK    �{?�wR|�*  �     lib/Statistics/ANOVA.pm�=is�F�����KA��'�)���;��������e�$(� %+
���cn@���U=��&�9{z�{���,��'���󴚧�j�����l{6}��,���a>�ף?}�OU"�l��>���c5/��\>\�e��g�|�6.g��e4*����SW~y��e:?�~[L�i��yTQi�"-�J��r��OU��x~���yB��0����Cx*�Xj�U���8������?eE�d�d�/�ä�-|�T�2��Ӌ$����<�^�8�b*��1Ms��E\�X7�����?��߫��Xtv�w���7hu�zj~���C�f��I��<�׷�,���Jl��b^���t���ޏ����}�L".���.�[�$���|5̒���mO6ҕ��d�(s������Y���z�?Y��z�u���qt:�����`�ch��g�t$6 �Ӹ23��}r�B�>Axm��4�U��w�;͓?��ʋ����7"y/:}��.�CП��4KDTk$�G���5U\Z��F���IX�����~Q�Kh�a���Ȳ�	��H��Ӹ|7�-ʳ�mS�� h�i��zͥPK�!�I���g/^<��3w�1��?�-�U��#�dbU��y늯%2�z��W��"*)������c:�y^��-����&E)�Gt�^�k��_��.ϒ7��H�B���/n�=�H�i�2��
o1x�p���%��F���q�%���,�ڋ�
�p�(�'Iy5?ɠ�ת{a1��CN�'���ǀ�j^�/w���UAC�Ⱥf���j��w�U�t�+�tI9�e	l�1�pO�t���^��|�������h��0�HO�x~8%wQO<�˳
	��@Sy.U�Xj2���	�9+�|<@i�?a�i�����d � U�]�9��G�9�8s�:r�IY�ڿ�2EtBQ�_L����Q������	�¶�"J�"ζ��jn4/���]�)��}g[[�kN�i�K\�a2�LG<�V�5�H����b��+��}&�m��͒R������y[#�F��8�%��>� DpCA��W��]�o��ۥ����+�pA��V�N��r�e�k31�CDN��9Rd��@���J�s�������#1��9�
$G��h��@� �KIx���<�i%x� �|�er1I�5���K÷�h�%H���9���2�%|U�����Ğ�e�Ng ~"��#g� ��Y����FA: 5�(_O�>��?#([�]6}õ�o�5֛V��M��Fo�N��>4������O�$!�����{�H���>��j��E2@����g��r5l�Z� �� ���6n�#C�2C��	��.����	�-6B��N�.0p�.��"���p����5�0�^2KVP4N��5W4�߇�x�U�O�|bC$��O:�T�B���� �L;EHuaA"��n+���5��(�mn���A�ka G=3Y�#��ͭ�����ۓ�;��6:������Q����(R�1)��̞i˻K�S$+ʽ:*JdŃy�T ��1��ԾH/:��w�z�Q�F���湻W�8��A�>�:���ϲ �Z�ȟ�e�Hxv|��Ц��܏��a�؋�� ����AdF�� � ����4	M�Eh�Z'�E��G����W��|�9���lB�iVD~�w?�ݏ*��2$����>�e�¯���Q}:�� �c�=�k�:��f1H��ݞ�u%��8XɓP��,3��s<T$w�Y&fEU��,��e�6�Y�ΉQ�\�ÏG���<R��_)%ѡ��)46�� YF�蕳���i�a����%��y�"2��D*���UT��G9��[`i��Dh�a^/@Y��{�\�{bC����A����˟�<���<����!��İ Hj�<�ބr\�|��O`������	�g��+q�x�F�R�c�;�@�Ώ�1���rh{�"��f1�5%�cQ'ߞ~k��α���cRY�(���^���������[ujiQ�Ő�L�N�0R!yb�8i3XP6��4&w�����SK�C�����`���sa��Fgh��i��k�����:4|%�9!:�?�o�H��k&2��X�����̫�Ӫx*A�+s~�=�ԧ>���(����8,���_����BՌ~�z�� 1EM���~;���p���m.�h8܁$�H�?��q�,�l�3�W�?>P����P��w��ھTM�Y��Q,$�O� ����L�����W�֚�G�?��;�;����;:n�n��G ��v�$ă�V�8�:�R}�&���Ə]�-F��Yw�P�%���/�����e�����`����i0�(@�po�&�(�&EQ�DpwU�K8 l�F�ٜ�*(�� kF�T[�n���Χ���1�y���Zшy�f�P����r|}�.ž���?�,�>���j�k�Q�~L?~�oeq��u�a��-?%���o�)ʷp*e��"vuiu��Ik)�����3���e�~�!~�Y|�3 p�yJ��o1C	P��\\�q�V3)��0�O�J�����_	��/aoy5MO*l�Xe��6��6��&�������Ťn0A��G��F�7'��g�*U��z������m�G�ܿ!�	��=*��*���߭#:����a?�`���PT9���J���û$���+F�x������'k*����[��c������Z�_pW����@��O B2`*2fa���S�ZG>eŨ�Sṽ���Gq)�puh�����i69�T΀��x��P��9�.�!����`�>)A�Q��:�-�>}��S�����mKX-8��8搥co���x�0D�X�M���&e�@_��0�֓��k���%�bK��$�PV¯�b���6R�3H^e|�jƙ�$h%[G���,6Տo�K7�!O8���5����eB��N?�."���ǲ�	��	�a�ݒ~�����`	�a�<"�F?�D��T��kh��ob
jO�8m��#����+�筭� ��ٻV�����W͜�ݻ���d�y�}����#���I��'����t�!?���R�fz3&����Ǜ#$Dի^�\\o��kT��mu=N�q\���Pc��݀|�Q.���ȡ��ja���:\�<��R�-�>��Y�*��A����P��k�헑���#��@?H�/�a�u�"�g�D-kӦd��M	.]eK�&�m=�1�Do�rg��֠�X�����|�t�Z@ƦJ�:��F����q �4�G�£ ����c�L�ѧ]��GT�ŕ=�NM��o �x2o;�)	�8���^�>�x���&<��Wn���D�����2-���Չ���IFсO�u��+벹�O��*΋�8p��3����r�L�|H3s�΋)�[�WG>v�+_ef�-&M���{����+�_B���^סX�&�p�>IؔB���N��	))V�$&��=�B`���K"=��H��@ww��>���pkE��[��Ru�VO���7�1a�rEp��Np���U�YS��/��ꚼ�޵�34���H�\��A�]F�Dǌ��l��@O��THzj���$O����޺v1i#L�v��$~U\p��2+�f�d����<�����bX�I~/��)�eg�DK�o��b[�C���FyUܯK'0�'e�����y\�;qz�����d��"M�Y��5�3���^?R�7��>9r�*�}8
dgd�(�J!���z�NA>��R�I�����ƅ��¯e|���=ITU���~�tn������2pQSt���l!��d7�-CU@F�l#?z�7����E<�����O��y#=������
W�Y��� 8��S����Y2��m�d�ǡH[v��U����|1Š��<�h�H��o��V5�� �AlN�tX�6WﷵMB��{���p���;M�.a9�e��t�����zZA�k[ ����-Z����_��U��oϓ�;���[��7��[���g�#�x-�L��,��dQ�g�8��Px�L��$�<�ޟtz�s���O��׺��2�͇?�Б8�m��q����g���p%7��0��CQY����Z���2�y��:�M.7��+�D"*���_���'�Nv�{�sI�;sO͋�9Č�ڽC��ӻe��af|���Qㆅ�Q�WK>��^^�����4�ݜZ�+�G�뛪kϭ���5Z��c��U���8�H}.�^��5b@��Q�{����F��j�{��Ҙ�S�v�ӱ�O�9��Z�̶ oI.�?>����� �|zp�(�d+���������]2��\�%��b8����z�hJ�U�5Z1CPk1m����)ó�5����j�AH����?n1
����B�\4]�Ƣ���Fʧ��!T1M�>��ۄ�{2P�$GJlFf��)A߱�V�´�����8j���};С1M���-� �D%敏q��M��$�`�J0͹X���W��L�u� � D<~����?g	��+˰6�QdB�9����pc5Mg�IN��9~�d��G��x%l"����AGw�oL^���%�L܀#�����luR,�;��_#���,/s�T��6$���>�J6ܱ����{��$�Z+���n�1�{�� >D�>���Q�iC9^�8"�`d��D��l4�R/�O��I��c"f=�ߞ����!�M:���y?� @���n��_&I�R���}��1�@zX&�0"����-��':{]�ʪL��h�֨��'�B{~�7�5���Zu���:�k�6.��ʍM�Hs�w��+��|������Ihj>
�o\�0kZ�1`>6[M*�����k��X��9�S�[�I��P�5�Ȏij%D(���s1ă��f� �����������i�ox`�.�;"^q>�)�*��?A4a�MO�$�d`E{�jt������ewqխ���t�k��7�5h���A��[��4��4����e�m�4�30���Z��m�O�8��y��-�M[��RmZ��\`���}n�aFkV$0��kdP~t$e��O�G>�n�>9r
��_;� JP�2K�3���"�@y%8K1�R@��l��<��;�-$W��>Z���d�0Ӈ�Y!2�ǘ���\dEae<R��ǊD�O���ږ�k���v�^�ِ�q"������b{{�9���f�ބ�^iGU,9���
�7޶	o9y��:�z��!K�`�	���
ڃB�OO(A���8��-�Ț��:��*��X󻖌fa��j|@Bki[5k)B�T�Ў'g �Tv��͸���1k��[U4��l�V�)u��
 �!6����7뀄�ٟu��x��zj_+��<�qNy�/|C�%���-���X�I���~h㫅��� �
|'��f��x�11'�-x�'<��a�����/Fv����Ȼ=�� k�C	$��C�m�wK��5����ਬ���I;H�'��� d	;c4]f<��Y �Ȣ+n^���C��(X��f���E�G��x�(��T�x�B�����p@Y�h����`�<�sq,BB&ʕ2�X��+�[�N����t���[�(� V"��"��q�� �d���3��R�u�D6�M8�a�H�o��k�g�Q��� �l���#7e0�'��h�js��7��U��=�C�=�R��D���Jw�Ց�@��-)ļ� �j2�V:]���
}�w�f�7�v��g�d��\��0�F{�mu�.�	�j%��E28�LQ�Z䮳N5�m�{B�v��\��P��BN���#O/.ZPL�قf�H-�]lz9�dr�q=d�
q���"u�6/.B��P�i��
�W��8��ّ�����2�2��.�bL����m�d{oWD �]��	'J�G��J<H3���i�)tur�[��xMNj�9���U���2٬(� JX�G��O/;�>�S��][Z��b��6U|�}�%���/�T\�6����V�V����⏽7��H�;���F�sE��cU��`���#]�F�4�
�~���+�C J�3T��m���v�o�.VS��:eU-wk�;=��M�s�o�K����Q��LPK=�����	�^�/gsS�,ōi��29ʎ66���ڌ�N!(�\ͰƤ�t�h��<꿜'Ifή7a�:q�5�xK/ȋ"��i0��p�]% ����9�H�3Q(Ͱp\S��2ͮh/W	0�}+���`���<�n�1��3��N��@9��(�KY����)fۓ���U*�T�#k~]5�i��%n:B��Z�U(�>�*���n����x��e�t^��t^^B(�����2����v䧮��K��hC�Aى�����QA���Ǝ�ʶ��R��J�Wʦ�;D�z�M�B�I�k
��5I�FقnX��i�P���.92U� ���e{�ΏH伍��YJ������0�=�I�Ȳ���`T�։ �bC����M%^���O�
ePK[&Y��X8��y
�J��1��2�{���V8�t��0��7@�T��?�it�L���h��/!�v�����F8J�fK��wv����˘�aX�����c���Y��3A�H��e�1!�J�02C��h�M��jT��ŵJ`g��T_&�I,�5�����x������T���R{B�J>cͪ��[�sZh��A-M�"�k�6V{��/M���/A|��o̍7Z2����ƅ�/�x��D�k�w)��R{�u�Z��F���� ��(�����G����i�!XW�"�]�̔W)��V�٫�҃�
�EYxWb4{�hL��\�^
���A�7�<D�\�u)����e�w�^-�YKĔ�j�/��T��?�.(z�RiPT�}�i��K��jA���v���,�:�8��1�u�� ��g�	�S7��.�z����Krosh .V��p���^u������g�fL����H&;u`�Q�<�eh]dc��i�=��w������7":�@2_�`�a���#J�jt.>��������ncC$��s����R� �	���w�b�<9��� Y�.�"]cm�� S���{!�Uz���tB��f�Ȳ���͐�aK��vI���;�hLC�nZ���ܧ8���!�h&`�h�hD�e��'O�?k>I�t
��(A���W�_��N,+��#�|[;n���$���<k�,��}(��}:E8�,��ir��ǡLt��ш.�=���U�4����-C6��ׅ��nR���2�%�g��$;z�m�gl�R���ѝz�a�Z�H%J{�Ѝ�,�+Oz�#r��^�dN��>�[��m�`N�%tz�R����P��w�k��ǋ �4�M7�x��gO+��&�P�m�qBZ�I��؃2�
���fA�87$���=�OG��噗b�X<��%n�mG �m�j�u���n�
�	4��'f���#~z�ˊ�v��Uv]X�^��e�VIg�*����_�3'd���b}m�"InП*�����9:/f�����~mXwn���U.�wq��0%�ɚ���-�wO�e���x�oݩ���G�Γ�L��&%Z�����~�����1s��H׭����L*����2��~(�d<��mjP���g���f���nv*v��uI����p!SlF��u�j��+ɰ;�;?���-�~����x��G��C�:� /�5		/�9�$�Ͻ�*�|7^�7��*�|��J�%�/��/ʛ�?`����N~�v���E[G�����]���� �b=���v� y�C��P�U{��o��>[1��*��NP�U��@���@\u�ꊙy�yP�'	_>�=I@/ÏD���������4~iI��8�����I@R�z�:��VY��RVߒ�.�)����r�?�T�L���5��I��(Q�ҏ�|�>��p:�!׾�H���R�^�����_���UZ������A��(��B胲L��G�:�<��hK����zh���0L)�%;��Y�~��v���ŋg��}O�nK��J��^R���"ɋř��T�>ίz�
�新d@�D7Bv���~��H}v�ւ�+�ً�s�=M�y���b'(�����w��ֳ�'�a2^��72����8�x�e���a�*��L~�A�\�C*&@'ŧYQ��`����8�RF�$џΧq��P��b1Ov)�>t�pz�P��D<K��j
oJV��)O��a�^���0910��0<e؀3��k%}��4��Ԝ�=|���X6�,�-!�^�]��NYӾ-�i]*s�@�X`�3�6� 6�9��ܡ�D9W�" �3�q)s&2yW-b�'���-9% uO�ή���l1+r�*{��:�R�����IŎބ�6�����KJ��k�k��;�}`ɗ�'�Q�c�م\i�S�L���2U���6�&x���os}�k�~��G+8�؆B}��}�-5p�(�8xe-vO�H�]�HtQ4v�a�x�)��<_�s�W���SM^��r�0zr���0��j1�H_/����"�/D�N�v��KS)1 �#o�
�?���cI�H�ٯ0�� H􌎫�j�#��}���R�!���^`>��{��C<E����|}2��[_�p��������|���g�~�b�%Q��m�wfQ����D��犓�vJ��=ۡR 6�@:�=J�䣷�ʐ����1�eC�y� ��]���~8�d]�1���� <9V||��=`s�כ�m2���u� �6Sta��т������o9#�Kc�����V�*��Q���,݈poʵjvb�h�ɟ]�����-P�-s��M�G��Jm���F�2����k�w���a�����2��dv�Ȑ*<�F��(�p���7<��>�ˋ`}�E��|����0G�F��@b���:B��#��A �W`,��<g�/�=����E�i��~�˳�~���?~K���Q`��":a�f�^���_EYe�U_y}��{�v@BIM����� ���0zJ��]�s���<ҷ[QdUϤ��e�|�tQ�M�7�U٦<>���*!�ε&���C���~��U�4S��	�]�DI�)�*���M~�;�2�	Ӳ�:z#��y](~J��ޒ^*�+�Zu�B��ސ�:��-%�<~n�+J�;V\��=9��#u7��}����A�hR(���D�=t|�˜
�w���2��&O��+� �����ݠd������9��N걘ڳK�0GBP��%�����2�B>f����@����=���%�J��� ���K��ǘ|���9DbS~Zu�t�a�Ĉ�
�{���c�C,��)"YT]2X�l��T[d���E�R�����J��!����ŀQS!��d+����6u}���l'�U"̫/*`���D��Ȳ˳�����p��uQ�&UL�_}�7�QYT(RMB@��l�H�}K�7�U]����S�܈��%�=-8��DE���CE!�9����4���	�5,��u����΃��>�A8 �� �q<CF5)���&a�sqvVu�C��C���@�>~��'�[���i�X�мO(�gc���9��|���b��R��ҸzP����*�L�(n��F��Z�9�-� 0�1��d���}!eiD��U�iKs>�j��0��z#���Fóڲ��ډIhL��1��
 �Y�9;����P���^�{3\���k#M�Y���ג^9z$�
�d�ub�)��e}�]=�8�s�.V�$����^l,02%!*��oE����i��Tw��P�S��J����E.��](�#/!���ȵ�dЀZ2T;.H�'�T=�����Dh�]����ŜA����xn��6qنi��/�Ȱ�FmR�W��i6�x���t�΃�6�v��0�������#��nɡ�4���(ĢF�u#�+��j�yMpq���ud#D��`��,lC���O�Ai�J�9oQ,5��f9���Q"Q `��'�J{�Z�j|z��6�Qzs���P�	���!G��Z�=Ǭ��&��U�lz�M���u-.*Ip��'6 ,8�bN6>d���A��Z��Zb-��y'��x$%,Os�>��X8KQ��#xqy�`|H�%+!3K����/�>�����n�Nn��	Q��}19i��k̈́3��r�Ǐ�",��-�h�����A�V��#��%o��)�U=C@k����m�c��I���?�z V�`5֠�����m���d�������QtlհF�+��ƕ��麟����@�t����"ˊK<�����G��4gQ�k�YN�_�S%���\/�(�����m��u�ol4���\�|���p7����듫f���Vx$�6H�xd���mnL�!��2Mn �������ꑞ#�\*ft���cs�dZw7m�-�y?٨�7>E �]O����O6-p]ck|�w��#DC��d��\h�!���ꁈ���p�G�*���˲D�Z͑�]��ռn��6D���)c Z2Fvj�,TA��^��FK����x<y���=���O'�����;Њ�M(L?5Sfa�JV�@CIpf�?WW;���|���W�c�p[4��
�JR�Z��1z�b�t@8�DX���/�je+~�w怾*��(�X�b��0���w���N����?}�PK    �{?�~z�  �     lib/Statistics/Basic.pm�WYS�F~���%��m�}�����Zb(�R��D5��^���(�==3�,��x�,MO_��t�vl˥Ё�4$������2|��h��x&K
�n�'���FPBfa_���Z�2��s���i9s�z��9�^�@y�M�n&0�V��ӧv�՗'D�K_7
��Ln.����@�<>�z�ϫۻ���7��;|~��]�NAC�����V�_*���wt&P���a%��'P^C�})&�@ELQ*�k(�	TU1A,��5�b�	.&��*k�j)S��DxN�5��{,���Fx4�����^��\���
15B���9~RS�J\ 1e��I�L��E\��T
�4��ABӤ�x5�|_Sc����\�.�bæ�y��+�����Bl}#�iSݱ� �I��ѠBmh�̖_S'�O/��I ��!�J��<�9XP��>5,bs9���#WKF}X�s��j-]�Q����-,�~3�<Z�Y>��[�ٔ�E��"������̜�����5�d���%���	���(��ރG�P���9�}�C�g]�\f�������R���c�	� ��aR���.�Im��������.�l/�\y�F�I�����*���cU/~����<c�b���d,�7����5A$X�L\�ag\fa�j�<�<���h��l����v�5�A�UE �56�y��sb�P"]�363aT5\g)���� ��
@�d�r���w�pB��[�t+�r�t��\�����<���%��*��ff��$h�t.������D4)�"&��G�T�"əx5}��z������o+�5/�SQ/�p+�X�k0񢽝�V�ih~��V����y��Feg��s�N���Oy��9bo1-
M�ys�:`{��>![#v���ʨ��*0F�]�==�rz9ֱ:Q�M���mS[��a5�D��$랼M`.����;�?��FEexxK�T�3�,5�vj�e���K=�.z>���s����v����s�`�����?�=cj�=e�u�\���jb�W�fd�����PQޤ!Yful�{��y��N���Vs���ǬV��:V�knj��Uav�ϕ؍:{J��J6�qd�Q-+ ��j�8�(�}' ?��a@C�T�P9Եj�~���D��(
�C�L���OI6��'�\�'bh��(;�8�h9��Z@:�7���0dGx Ǣ|ﮟ����@Q�n�I4�]Gt_�,҂�w'�SBc��a�IbiJ��T���I��ci�F��PK    �{?pd�    &   lib/Statistics/Basic/ComputedVector.pm�V�n�8}�Wck/�^�o6d4M�.���h����@Kc��,�$������-�x��i8�9s8���'o���Ls�y�^�c���.�.�4F_0�B�Lw�`����m���x�f]��`�)�%��<?0��d����)9�L�P�M�d�J������o���E������|�<�*[���o��a3����k�U���i 3޳��l���c(@H�`w0|k�7�'���eJÊ���4���eʃ,��@E��RD��`�%�qʁ������x��ȋ	��{��0�& 2ݶ>��6q<ٴ�g0L�Đ�a� F9�u&�2�~Q���H�u������C|:�����2,�����]�6<�i=��Қ_�mn�B�OY�ِ#�k���_��=��_��� �z�BY���:X� �\�M�0J\��J_ƨ�"��RY���� �Qbb�'��L�1�w�.>�_z�rJ�Jז��.��L�fךǳ��(r49�{KCJ)����3�C恿p���`�)q��+*R0�u��F��K��f�~?@�1G��xGҕH�zd�E�S�H�缒b�ٹt�HI�����bt���������	Z ���N=�H�����+q���ॕ��2�x��]��������W�X�%�ܕ�B�*<�gm>r[Z�t+Jno�=yVA�S��0����:���*��L���#���!۱=���2�� ��I�4�|��G�k!��_���Up~}���υ���d�y���[d�ɛ���׷�f�!źS+�[����sF_Xv+�m����C�k���D!�䝘���VN�T�{N�kP��5(A��=���`��b$&������2|D YX}n�T&�0��%¦"����Q1[�8�=���fW��5���s:Xjs�O��:x�����u00KSL�S7�n����)�x@��PK    �{?�E�  �  #   lib/Statistics/Basic/Correlation.pm�T�N�0}�W�
���V�e��� ��3����N[��;v��måKg<sΜ����B"�н6�m�g�L~6͕�9s9X.��Β�'���x��u8|G�N��Q���[?3%�|��ߔ��w�g�:i�K>翑�\�O��$>�j����^w����G�a�Q̈�[/J�b s����
Q������}\�v5,�Vm�����%�l=� W�UΞ��"@KFK���Z����UuZ[��%�K��'������Y��Ų0�"�M�`<q�y�
M��3z����Jgq���k�]aYK ��b4`�!`ɻ`</���TP�$G_`J�V�v�	8-]W�E�i���n���3E���a�iyhllc�U7���QU��*�l�7�d�}T�������Ft�J��j��R���f�]Џ��O��e�ε�n^3��}���Z��8��S�Q����d+8�88�i�YTs���΀��랯�}���_�.v9��t��Ɍ��JQ7-��� `�����/lkF��������2�W�/��6M��W�s��ao3ۊ3�H�7�ی��B�C��z�O��K7�I���͈�X߸���~{����Y7�V��t�>�����m�I�ۉvUy��Z��չ�nH�I�PK    �{?��9  b
  "   lib/Statistics/Basic/Covariance.pm�UKs�0��Wl�L�XG3m�N�����%�x��?RKv����dad�i���V��~ڗ��H90���R	&�.���cV�\Д���d�y����{���h�f{չ���T�`jn�4OEz#��G��[�%�e��|�~s��|��CH�l�[O�z����XL���X�K+~��@�o����dҺ&/_��@�B�%�a����t�d|�md9�<�w0z���s���
N�W&���"�%��������>,��Sm/ָ:��V�.c.����8\����lIub#m�tVap�S1�S�^�e����̜��mTP���T�W��0�ç����"b����DHVH�7���ZT���7N�:�ћ���D�sU�H�#���Mn�4�i+��f�U�<U��(�Ƭi���-�v'�d���=�tGN�;����Y;���7��ܹ�����[q����
=� ��lms҇�
�z`Y������2�5"�W���j@RHK4A3I1Ooԭ&@ބ�b2�"սe��:n?�|%R�{��u5���_�/�~�aW<�7	������ol::Z�y��֜h(;�2���3�q�W�J���k�VQ4�*'^I�v|��(W�Tm��_�=8{���[�
����FC3:�
g��ˑ���y��)q�����?T^�z1I��k�����G��a8��,Gk,Ls�g7w	u����<k�����g-['��ˁ�\��~��_]{uS��H_��&�n���Dz��q�>��N�����1�0]�Vv����Q�PK    �{?�wn��  �  &   lib/Statistics/Basic/LeastSquareFit.pm�Vێ�6}�W�,%��ڏ6��&E�(�I_��@K�ZX]��-8��)�fi�5Z?��p�̅g��	����GAD�E�񻏄��WJ�x��F��v���#�y��(��J{>�/#��`���}OX�ϼ��D�N+�	>F��}�7�D�P@GZ=�(����i��a	<]�QI�/���H�ے����8� ��'�HL���ED�q�)�-wC������G� �}�_M�?R��E�������u�;H��%��1K�b\�~��	<��0Ŗ�<$@D�;�8�����2P��ڐ0\��H��n �N9���[" �O�Ї-�(Jqσ�m�q_x<�C�4��q1���x4dh���U����m��J�!#l
(��~��q:˳ח�l*��f$�J�$�d���ڛ$L����B�]�6�)�*�uH9�c1.%zU:�p�,�g*\l��^�R�<R��["c��2*RKC,��M�G7S��a�$�XٮN�2v(�gHX@b��9"�S�t�hj_@�����x5;�쭨^��G��d�5P�|e���s[(��;��o��J����4*�ՊB>]F=zu�����k:O�}RA뢔6nL�O�b1�����QE��H2I�媉We�ƪ/|��#�W�k
e	�M{"�Z��s�`Q�+QN`�l�ؼ1G>��%�.���IW��1���T�N��e����x���w*5���<2�|�d0��ٔ&~�+����>w���?����@�������:m�SU���z�Hh�[�X:}���4K�~�M���y��J�=�a��_.A���j�dkW��J����[�Fz�t�	ѥbe���0t7���f}wN��ܴ�
W��R�S�W�F~�9��>��l8q�^��h��s���=��-���Tum��ު��.���0������{}u��tM3�$�O`y�RӮ��g����D�x�/Ȁ�;�jZ5�&�PK    �{?�4,`�  =     lib/Statistics/Basic/Mean.pm�S���0��#)A��t{���z�z��K�B���Cm�U6��;C`� �߼y��^H��!�a��
n������L��e5�/�p��v��u�8�`������i%����OL��g�Z]!ʾ+���V��"�i�����S�`�%30Ϣ�B.�U��w�����D�+E>y���>���>C�	�%����L�9:a�#�p�fD�}����CA��u�^`�pa���d�ܤ�mƫ�n,�uX��a�F�Pg�@��XДrZy�N�&=�հ5�)1tĐ���ȣ�2]0���L#g�O�w9��C�4%?L|�Ԍ�&]3�Ť�'�w��mP�2#���Q��1�W�)�s����,l�4�qV1$�Ì2
!%�1,�R��������e�Whޔ�2���5Ϡ��ê������a�"�E��5�x���YvCdP��%����p}�����mgmE��G��Y�GD�����r's�U�wkf6��r� PK    �{?����&  �     lib/Statistics/Basic/Median.pm�SM��0��W��Z��m[�T�P��"����ImgWl���Ǆ�BZ�y��y<�B!�!�m��
nf��>���`�<�AP2���r�P�eK��2�j�m���L+��[}e������U�K�_�д���j
�����c.�1�� ���� ܴ��|�O� �0������?? ]��G���A��`'����gJzȓF|b�[Vtڧ)	��YP �{�������ՙs�f�/�eeQG��Y�	h��F!TM�{���V^��=M��Bv>�͐:jX�����ω��$h:�3��I>p�����ִ�{-�B�΅bRؓ8M�W�O�/���(�b�%�b��gz���
���])wmW	S�|ӫ�)1O`��'`e)g�  pԖ��yu4�)���u[qd
m�3��ڹk ���x�*�����P�lqv�U��&��z�|B
G�9״������"�uosW��r�>s;@I/��h\��6�-�_�}�o�wRwt�ȱǴ��u��;�A_y�=�vv�<O�WPK    �{?�)=AJ  i     lib/Statistics/Basic/Mode.pm�U�n�6��+�KH��{�k5�vQ�P�h�{���D(R!){����C����@t�Dr����F
�����1'��>|dV��?u��uGQ��+{A8�,�m�r�VQ�X��n�~�QB��n�+3u�D�ędf��섄�}��h-i��a�3��=�K��N��iȡwh�fE�L�x
�l��c;�K�]$P`�k��_�ϳ�As����1
b���հ1��QҠ�����%aA(��֒9��ʢܡvO�h(+7�Jm*�r�T4ɘ���M��ϧ���u���o���ﬆ�^!6h�@X��-*]0	L��R����Z ��������]0*����g��U"����а�2��`�Y���fɉ��dϬ�:��*wE^��}��uqɬ%mv+J�];��Wح?S-�kU����ϿC��a�Gm������. ����)wT�㵾�\9ˈH�p���=y<#�p�s��/�r���!'%1���j��Z�{ix��g�qw:C�K�����MCt��O��SW�� �'U��3~(�O>0�d��I�-�`�܊�(�Z���%�b�E@�OHN�o0�ڍj��"a�1�RH����V� �������8��[�T�1ũ�{e?U�����w�7������E�!]:�M��{���D�S�s�׹�9~�͎r��R6�}��Qv(�;ޑx?�������i��8a?����/k2r �O�uu�W<�^��B�	*��C�a��/�要�{M�푥��B���pﯖ�M�� ~��@�W�{��5���c��.������58<ܤck��ZIꋱX��6�b�PK    �{?�(��       lib/Statistics/Basic/StdDev.pm�R�j�0��+7����1&�t�챇�\v�Q�q"�ȩ$���߱$;v��3z�f�=ݔR!<@�j���Jn���Պgl8������Z9�j�ai��X-�M���J����O���e��_��_n��JS�7�~�):�o��k0{YP#��:A������*Y��J��_Oo�![ÏPݱڽ4�?oK���6p��aZ2ő@�`��6-ذN״ل�eF�-�Z�4p]��=���֮O�t�C�e�Y���=�\�!�uO���ڜW�cmQ/`n���!IA��I+*#u你((qf0O �,�|��%Ө�v�9+��2/�`Y�.�6��I�%Z4�T�B(ڑ_$�ą O:�V��aK���7�*�8�V�ꠐeI�5��೨Ѐ�P�5�����dwԮX�I
�w0��.�����a/|X$��Tcg��d����d�Rꩤc��Z�R���F� PK    �{? ��8  �      lib/Statistics/Basic/Variance.pm�T�n�@��#l�&-q��(u[U=�=D�%��z�U ���#���;,k)u8���7o��2�D�p�fZ(-��-�|���`��m�:[Ɵ�ᄚ�l>?��)��Rp��&Q�U����ւV�~&d��덤�\�+(�Г�a�3����DJ��~�	��؜/.��I�|]��(�]��'��5�U�D�>Z����0���ep4�@���Loc*� .7�Ʒ'&�	��~�Q�|�oK�r���D]RuD�$�R�ZY�F�vՉ.���Y�?��`��ꆭU��J��Ț�و��z3p����D�2�i��i�y�M�T�M��Pc[W��	&U0����N�s��6��Ə��(�AWrY�h���:����t��D,zoza�c%^�A�>vQ���������nHU� �++L��w�<�z���n�pIYҩ�ʣ�������ypq7��Ji4��}��U�T�U@�Vl������$��I �Q}�%��֙:�C8��L�7���SC4�����ʮ�g��N�m��>.���~3��C{;�ǫesI	u8PK    �{?1CX�[  �     lib/Statistics/Basic/Vector.pm�Yms�6��_����Ȏ��&Y:����4�v�$37��Q�Ċ"������$@�XM��r�L,�ž<�`�%q��
��d,d�W�0G�>�Hf��b�,��	�Z��UBݮ��ZK�A�<�dO}^�<�Ӊ��^�|�?=D,ay��A�	|Z�Ä�G��l�SH�l&�$��0]·<Pw�̡-��A.͎;��l��$c��ϋ˗/�? ���<c3�|�� 3�+�0B�GoX+�,�EG+�Z������Mk���O�j&�HG���^�^rC�����1&b���_����\��Y>g҄�o����o~��{�^�fk����<����[���7���=�s�r��/��7��GJ�����0�+�W�Ę%��CSW=8�Q�)�KXg�dS��8�`�ǠB�f"}!a�s�Sy�j�A�װ�n[����*�%L�p�i<��j��J����>��F" ��J��A,��?ݾ�����0 ��MЮb4 ;0�	a8��R1�|�Jer.��*s�TH�F��1�3�ai&�<�9�������u��R��I�r� RY�����Ҫ���?��@�l�����'���Y�cp ��N>܄�h�pD9gݦp/ղ=j��к^����e�M�w���c#풰�+�*Q><�lKT����D�����}>�������R�l�XJ$�ҧ��紡�8�>���Y��
h~��ǜt s���jM�.���҃��,���d�OZ/�{������2�Q�m�
��U`Q��|��%
S�G|� V��λ
P3>:���gp1�}$�|�3#`BZЇ_�8��M;t����r	�6����Bsx;4TY`&�X&$N�}K�@o�a�1�SS�������{ Nj�ݻ^�xh<�瑲S���gf|�����6��;NJ���qJ�x%'�lFS�b{U�yL�7�*�n7���
5A�aYQ�6RQ	�i��t<�g�{ *�J� ��X1�	�|ǂj�1n�H��_C�fŭ9%FI�y�G�c��9�2N�(*(8�K' %۫�G���^9��L)����y��߼}�le,�nX�5)7�f�U"�Ίå��S�5�s!*�˂v���s��P�h �ތ�[n���dO��c�e���P[
��)'�׍�S{;�P�n
�� �*�R��m�v�е�t�YiGܩ��ٲ<z���8�\���r庂��;H6�WN�/�D~Ƒ��1�uj�-a��p��	T	r�&�-ju�V?��뻏e��g|d�F�|췹&&l�kr��d��O�����������RL��ܴyoG�d�Dɀ%�Hªz�ǐV|ˠ��[������xs��\�g�w��M?��x���-�E�qY�A�=|�=sI�4�;9�����`���M��!���;�8ء�φ�Wl��)��?����k�Kn�b�pB��)�~����fȑIԂaW��$�)o}���M�v�z�w�>n��=�o?����{b޲����X[<�s��q�bI<r_�:�j���T�S'󋾑��Iv�f;�.ל�dQ�X�~q�T����C/T��J1J�>u�V\0#ڝǠ��ĩ<,�<�U��i޽�xw�p��ۥ�2��c�#W��Z��b/ؗ=�m�z���)�3�E�gL8��N���.!;���rT|`����5'��z�|!�ә.I�G�C>e�Ӯ��S͒dԂ�4N#*a���	�����S}g�_p;�QR)zC�����]�ya)9��3��m��rWn!,��Io�Sd�]5��&Rj�*�^k��:��PA5f��ӛ�1��06�Su�� m����.=X[ �6�c��Є9�,
�Sw�z(��G��'�PK    �{?/���  *  &   lib/Statistics/Basic/_OneVectorBase.pm�T�O�0~�_q2՚0~��]:�Vm��1A�P�$�6"u���*��l')I(&���w�}���$f ��X�8�'T���w���re��rA�%n��1v84��a;zdY�@�ǁ��=�,f3QZ_)_VAO�F�z��3�@����[$T@�N���$͑k���	�;V�>� �H�ڰx�^.�������]��H9p�g@�!%#�mh/Z��q����>r��r��1�石ɹ�^���c�M�xa�9nB�����9���6��/�M�7�'��l(��SQ»1(��,jYS��4iD�H��a�[��Z�"SS��S	���4KB���WY)!c�&A���%G�LX�x�CT��j��tŮ���2�<��xA���x�J*T�@M��#�J�@��&�Q��fD��t��&'�+�rjFV�(
�/U��W�3���OStc�J����^N���5��~Ҙ�����o���f�@��^���/v�Kכ���eRuK?%��@\�#�X�`�V��5\���(��������j:9�z_.�?Nϴ�q�m���-#��U����Q�����htV��^�����<���;�p.M5DGŦk�QW���������=��1��{m��w�>�K�W�u���x���g/r�v�r�,4��
շT=�� PK    �{?��E3�  �  &   lib/Statistics/Basic/_TwoVectorBase.pm�VMo�F��Wh�&cK�z�J�M+4����\�X�#�5��w�T�����IY�6A�����}���͐gq�`�)�"�"_^�f2��&���J���JLc��"4��a�<v�G��I�D�Q�a�G<���W&V����A��x&X�Z"���1�%0ډS`P��kzm ��M��1���\P����5�`y�g��c�b|�U&8����#����HTo�HEǳd��6��yy��ퟷ�;���6���t�W����Ц��Mn��s�m!���K4�̜��gOC��l��J��2�x�c}�y��-�A�����Izk��E�����6K� R�I�8�%[#YIdт
IR���
V%r�7�3(���v�T��H�h�)�2Z��
sa�=�>�}]Yv���$��r���c	lB�*���-��ao����'n�G�m����
����鑑SJy�׉y2���U�S)��F��f��&s
�
o[�FS0�rMul�]��r�����qj��.�����2��I2Ai��dp��UXz��$�WE.|���S�c���v������~�����DM�Dե�1<CHm�Xy���C*E�m�qn[5��j���j�m�"e`��u���(�>�zy���+קr�R��7�함��F��]�G�-�MJc3�j:��.q�/�lK@R�ݦ)��f]��u)37^#N˧���*h���z�Y���Np|��������_�U�)@/������%$�/gY�MV�дꨝ�=�5�=�*���x���*X�!�##4��E�dz�`��O�,�75�P-��aʖ���Ӧ���U�b��3��F�QRެ3Lj�����5SDi ��PZ��VZi1�?�K���!�Wǡ�����8�� �AWD]���2�&���PK    �{?��'B�  f      lib/Statistics/DependantTTest.pm�UQO�0~�ŭT"����B�4��6�j/c�Lr����*���i�4�?T�����;���\[n��"2�.0Gsig34�$�,��=�CؠNO��)+��ZD��g�s������o������oW�3�ɾ+!�%m2�)9eR5dp�11�S���'�d`��LqlɀV��\+�  3	e�2G)7��D�9�OO|3�&,K�T����lix��������1&�.���ZC�#�M����\|��Z:�)+���Uo�x\��N�����%�ps�:��[U��y�9��Ru���Gg<v�x7�=Ҷ�[t<�u������:�D�u�t���To�li�ml�Sٍ[�d��$�V��-[��[�~�jbk�H���s�����6��v*�:Β�����0���BQ7L�Z�k�@,�5J)�;;?���Ei��s�1�٨R��6�i��zq��h��"&��E vj���b *!�W7��!p���U��Z
?p���a��N;�׃�a��D��6���H<g�O{D�ѕ���^�_��7e=|��o��oW�W����nֆ��F�����}�5�-�l��Ӣ�"�%�j��F�x&1�a��DS���$��'�w�[�>���ݷ��<�F�axyu�������G�PK    �{?H��{  	C     lib/Statistics/Descriptive.pm�<ks�F���_1��(����+�R䵕�T6�W��]�֡ b(b������_w� )9��}9Vl3===�=��A�I�q6f�UX�eOʝw���o�p�nt���:��̀X0��΢䬬�xR��]XdqvUBW��i�,ͣE�YT�w%���6N�lZ�)��"��b���h���
�+�J�;���,₳��h���n�W^X���E�b��р].*��׼d�b>ϋ�M󂥜�y�y�ǿ�I��fa%��f	��%a�ˊm��o�[^�q��|*�~��26o���/x�Y�+X �Cb�mX�̻��z�<=;���{���'��	�}`�n?b�{���h����G�4=!����9̥A�ZӮ�ʆ~5�y���۰�@��d22'^�yQv:~�y���Հ�R^�r	�O��Y.��m|Z�d�
B��d���(���"������C	�Ȏt7��܂W?B��1� \Ts�Z�d
��Y<��b�x
d~k_;b����^�h�>���Z���9��$_�*��Σ-�y߂����7����W���;>E���L�kV��3����t��=@2�Y��ŋ�c6�{���z-��V�����EK<������}��V��<�X�+������m�����7o~�� �>��,�}fW����eC��`��/Km��b{�F N+���G��;��lf��q���j��AH��`�$	Kl3O@���W	���Nݔ+A���\&0?�fH�>vHU3k�'�*��qi�����*�
��m5��߃+�&>�>{���aQX��O�\�Yb��͓�V����zB���P�E/���Wy3�����!p�FK Ϡ5�G�߰�7ggo~��%�	m��h��<��A�)wj���"
����)�p��`����jh�0&J^�<H��B�	T�M�B��<�`$n�Pr_�}%�`�\�ˈDD��I����h���S�8���g�I�L���F��=_s�F@hÆ�D�&���� b����M7�xrC�28��"1]��))���#F�Ϩ~ah�@Z9ģ\�ǌ,��&$k��P�=�����F�zkK�!+��Ѫ�ׂ�&S��X9��#��ߐ��F��F�V+�:t�P��ޓ��4�k���A��6�υ2E���@����L /jf;�2����n�'a���0Yp�@`��V��x��?���K�&y�R���|q5#4�a�z��yƒ��e1U�M�oh�j�@<r}�o걶�e`6�m$.O�N���ꪺ=UyST�xk�|_�gHu"��sJ��JqK� ��ڱ?��G�-��6bl���}*u\t���E8��˥�VX�� �H1��LT�<�xl+�������}���<�x,N!]�@�P%`r^:�_��Y�H/y�\��Ar(ǋ[��91�É���p§�T��yY�H����YU�˃���N�a6̋�����$���yq��..�I�Ϊ4�!����4����'�)�٨��9a���QF�7�J��!
=�W���-�I}�� n�F�`��F���4��f��m,��ȗ(x�/��!�Z�$�
X��՝���-�6�I⪍v7��x���QH6@����,���Wl�<hL@��,z��2���� ������O���5�xN~:��.�	2;�z��O�6|�$��ƃ% ���^��!M�[�fR��Ĳ�� Tuq�<��:	�6�6�T�8��"FX�gga�������â�> ��~�����I7"�4Eo��#p4I,��m`i!�'y~��"WdE�Ą4�3���b��g�%��K��h� i>L���_VAy��h��qP�K~\C���.�D�zQTy��GX���SY�g8j� �)�HT�S|�^�5!��銴v���X��-b*�WG��/#������iUĹ	�����F��͵x[��aK����\h|QđТ���,�`EF����)��,��j �^�K�B�I����8��2�.���I `u������5���1u��`L(qi�d�������B�U[	�����ܓ�-a{Vr�P�lr[���{1I��� ��5���_σ�}��Q8k���C�Ճ�.Y?�k�:�z�U��e��R	<dz�!��/����9 ����z-.zH���i�}�5e6������,��L�L�θ>,]�N �B�/���ee@����⃧"7F`��A-�R��!�2N���6Gn3�����8Ϫ�t��J�tE�G�d�|t6�Ա�3m�C/�%�5������E�'4�"��|��xg�Q�<G
m����y+G�Pm�?�c��4Iw*/��9���脴~"KLy���
8ސ�g콆��w�ĺ�>2�1[�7�]*��4?$�q�BJ��#O�t��
è�\��u:LI�!0S��
��ujn��4w#�5�1�1w|쇘����E� �W�Mb\��4\�H���u��A!Z�Jh͏�:H�O�au^�!(���͜�������鴓������퍤� ?�	��ɜ�^T��I�h�K.������l&
vڷ�� �*S�Q
&�ǉ�#}H u� �nH�Y��Hc/,��¬�P�4�Jg���D��BF�ơ���`�?G��+"�O�<�7�"�X�1�خ���h�����y�Z���^؅?Y:m:��9^�kG�h���>�.u� �]��WTH�ɜa}��}K��Y�@#���Sqh�-�~���������1��/		�1�0������(�8g��L��jih������a�������~�����a����so��a�4DS���K�F_r6��������l�0Ǎ/�ҵ6v��E�x~�W��#6bj��������i��i~�x� �9b�>��>��X�.���Fc#�f�M!#/<�K�Xk�erg�{��ʹz����a�:t8i#���$�cf��,Jg�53j��y$��Do	��Fe�"uo�FI�NĶ��ՕEu�nVln;�~�T��CU�7/�s����ħm��龀�x�E�vAXC�[R��hG��`dd���4��|��)��$��"�wK�[)���Ӿ��R����6u�t�x�k�_	(���l����	��E�	�֑`���c9���=�T�o�O�t��%6�ГK��c���ŕ�dTq	S��y�]�I������t��	Ԁ������F��h���%c4Z���+�5lldVhC��wKq�7��/Uلz0�=6=y�}k��2G"5�ױ{�7H'�*σ2�L���P���^���>��os[�_:����"l��┅�rQ\񔎢��Y����_ r ;�9]�I�{xw!���������:U�vzD���{X#%�E���G�ϙvV>��������`-�o�D�y�3~u�Z�+A�S�֬���C%�g�°ǵPOW�����|2Y�j��.,����u9�_�,Q��z�RY�X"�{����ӠNI��ʶ$(;fc�U��b�y����9 ���q@X7wk�<�U_dέ��GK#˾"[��^���X�p/<�#�/T���aV����Ƕ�8zDcת�P7�f�S}�.t�P�Th�����y�)aKԖ�HQ1}���S����N���'N�2�B.�����Ķs0�N���,�� �]@j�
�d��V2 ed�4o����@�����G��ɍ�r��2O��f��;����5�9/��th_ɓL\;�\��<��[f� R#��uŹN�B.ʔ#z4r[�H1t�-�_��Z�����:�l�	���9=B��`��� ��Dv}��/$9a�4�~�ZT^�!Y��F5���#�ߠ�j�
E��z��!;���{�%�����Z��Q��5eRO���g��Q�T&�eB��@�V�{�t���=&��Dڮ������2�Ծ�Jʭ��R꯵�&X��FaI�I��� ��"�ͦO�L'׸�1�_�>9ËK�=V����lmY��U⵮�ׂ{�=Zɂ��$�Q�=]r���+iُ5FX�6~]/�C��p�%XdH�b��	��祵��WMX�H�9z�5�k:�.�80b|[�`����E1y�W�8�ղ��R,h��Q��������>���^���mO�\�ck`0����6�癡R^晄��>1w�P6/�dM/֮6���!��M���W=����4����75���1�+�j\!��p܈X������d,3�I��{��p�l]3�*�����S�;<0BT}CU{n�C��}!�h4�	l g����������Wf�ļF����QI��8�zm�pc��F<�b��l#/�݊�kY�W���X�/�t&hi7��Cᥭ�Ֆ?�k|`�*��Xk�{�x�x�\Q�b"[s�TϨ�D~�q_�!}�ёe�[v����Rw.u����r��/��m�%ʥ������?��Z܏�p
<�������gyjO��W�ͣ���3|XT�E�Q�0��A:���͕� �N,�p���h�sԮ��I`��uf��Pm@����~FyR���zZd�s`��]U����Z�F�����=�af�޲�R pX�1%M�g�&kiw��Sٲ{�ci:�Lt�6�J�w��D��E
��4��/�u���I?�Ef��G�t�Y\�H�8@^�P��ϻ$OAؑ�ލ��AP�`��.�=���W-к"�����K3�R���(Q��OV�l}��w��:x��Z8�)c���*��~c��s1����7! s���p����,b"*C�J��C�1��B��i�u���4�O����h�c�����>�QI�a�p.�Y���Xu���1Чo�D�?'J��*|H�����  8�����?:�PK    �{?����  �$     lib/Statistics/Distributions.pm�io�����+&^mBJ�H%JZ��M�Ma��٤H�"%Q^�"��T,���}��p����/]`)j��׼7֋u�'"﫸J�*]��W�M�*-�r��.ڛx���>5ЫW��v{W&W���oK�Ӄ����o��|�N��y��x����o��N�}�7��@���J�ވٵ�0Me4
���7}w���_�|�B�����y��J��}���B.���*EU�y"�I���ɲ��&?��m"��7ŶJ� <�6Cq���rW/�e�	_��*ɈTB "��}��	���YR��1�d���@�+��X"/*��ւi���U"?'�Gq_K6.�| �ō��gY%�r T�b�e�m֏Z&�F<������t!V�|A��x,KO��k��i��v�^��c�>6�b.�^+z��	&2~��/��/� ����d�F\
%�'>$�d�B�˝��<~_�&�E�Wo��\
�Ï���(/s������/Eg��7wW�V��%�z&|��o"����}z
�����+~m�Z�47���:]�������/0����6I0�V�,�v�wE~c���NP� �Q"48��&��/�av���(�:k=�z����'� �9�e��V 8o��+#$H�d|}Z]#�2h�ӢU���s��=�gլ���zRկQ��2���ّư�z����t�;�ʮ� <��t[VO����d6��	6���2�Ұ|�����l��S?��+�jV�SEA���@Ư�<]���q���b���5���cu��X��{U����>p1���;��-i�W=��Q�~�^��GD�+U��g��>g��H���t�dVm�̲#��#�3�����n.�{RE�lf�H�%me⥐bf�6"�T`ã�XMt���ڎa��V�V8��2B_�+�Ŝ_���d[��02{��{�u�%<b$�;II���>;����%L��mh��ӂE�TU�U%�8U�Zd�Z��H��1�vҁ�����3��ҮLs��HT��b��@�����0��
�v�7G|��k}�Y|梋�"���k�Q H���f�R�tY45���#�(�d�$��9,I��:��p���=�a�0��r{�����G'5ґm�f�����w�P;H|��:Hh4}{�>k��.���E�A~�f�M=j�<A���7����A߷"'����R���O��肺�dh�ZL����SJ���'�TN�����T����r�y�Ղ��l?<i�����a���l��Jq����9�v��xy�p1�����w�3�U5��0��kK��	`0��i$'X�ش>�ñM'��FK���0��p4���(�F�=)G�t8Ƒ�3��h2d0�S@Q����h"�2����޵x�p$�����Y��@��`w̻j(���r��k!��h<�B?�_�+�A4#�Ӊ�M�����dM�����`��kg�tY#92�R :���^e o�G+�R�Ŵ�Z���I������I4�c�zK��DA�z��`����O�&lO�d���N&6����I�F�"�"O6
k6��P�(]�)��}����)�0�U�rw0���ѧ���K�b�8"��mZxQ=�o���T_~P��h�L��3�쓆z��]��+�~È@��/�XE��ӕ��uZ�hԝ:8�V3;=>�
O{�!��f�����\�֠�4�w8TG�N4�%#:���p�iaO�_�G�h��T��h&��#ǵ��%�4��c��8�/mʂ`<���$��b{eDJO�+z�鹠��,Q'뙧���> �6�n��._b�/8PQ4�8�bWz;������N��{��E[S�A�.JBo�����N+X0C@'x|��&4�K���
󉸧����O��E�ʹx9����ߐ躃���%�s)�u����矃�L�'�f�լ���p���Y�+��N�ӱ���vݬ�^�:�ӗ�3<@��y����(܈���G*
u�4'"�|p=�1���rr~Ph]��Ǎ~g���R�S��Hs|�$�۰��h|m�8��N�T׊��ͺ�nS`�uj*�׺�v�|��PIO_p�u��:��3�X�
�&놔����� ��ԔS��� �N�x��{��*!g>5�r�PW\�n`�e��ꩴ�	l��"� Z�7�@h�;����N'0�6�C�#����֌a���c뉄_�gb��Q|«�\�u����D����R.���?�6v.����9W��8K��"9Հ�N���~�CZk<|�{	<1��yq�������k�S�_��j�Α�۶O#�F:z�S�6f@�`�f>)�=��Ek|�ԇ��+7u�¿��(s�P����u��Qtv2��9�&6K���:���\���zV?Hu�L�;Y�����1����R�gc�59*i��l���૚�uS���i��A�fOH[GGud./r���2j7�נ��Y��?�IH���T7I�I�R�eu[fQ���\���%*�Q��Ӫ�n1w8����m�뚅:u���ҥ�8�pQ9{|��`��1�-�Do��)*+"go_��n`Z�v	��_��@:���u����͟�n*���n����֩����ϴx��OS��H؅�j��_X�uoo��}�Se&��zv�
��x늣���G��V��p!rEp�˷>�s��`M����#�ziU�0�E�!]Uu��r�[�Sǃ/�F���H%{|UR��SE�-Ȗ��uN|�&�TbZ�԰d����0O�?ʜ0��&�G���07�9qգ�q:9�U�/�O_�cz��@'�rf7�|g#1���@\p�4˴B��Y����;�����x����-vե�ar��	��n��e��߾Tb�Y�n�o�l�nC2�ݽ}���P�s�.DZtY���J,��.ÿ��[�,��%+��u2�,vb�T�>Y����9�d�6��PK    �{?�Я��       lib/Statistics/Lite.pm�W�k�8���+�ws�k���%\��z��8�����%�k�]G����$˒�4t�q�$��}�G==٧�$0����,�X�'�8�6',��W�E���~M�1+� Y�I\��;�K����\~�~w�f�����߿�>~2���_�~����uo�rq[&����l�"3֤����c�r��޸a��B`G4�r�$)l�=�<E���@�-�6��A,��.q|�i5���k�Y�?/�˕~J����[�q"$N�) ��z �>����μe��RYn�M�;�Sʭ��{x��e�����(�d��<�Y4�J;7�3��(ӵ��<ȏ>_̭�0D��;��\%K�o���W�,�����$K��(�fm�Ҙ���,���,�ְ�*��ǆ���;��à6� ���L��F]��a��x�|OZ���ł;��ǥ��.5�D�5��4��u}̌�H�M5��J�Nf:,��E�<v���'�Կ�����`4']g�o��!�#�J�L��pޯ�=r0���3uX�z+x�GU��$�+g�2����u)d�s|�3-�Z�IhX8H6����-m�klz�Ϟ�
��6�:�"7<C�(�*gt�x1�
H��vud�/��H@Vݥ�� �6/�0�d����K����W��������m7�Kȣ��jZ��~����j��wO4m�TݐQ�0;��~v&}�:s[1�>Y�ü��RQ�ඥGڊ.,b��dPK�]]��m8ꌉ5�[��q��c-���2���=�����D���&Ñm�y��h�T��yzɡL��4N�X����Q�iԭ@=��`�Ev��hS:���Ԫ�f���@e��m�nz��M���О����?������#1jB�;�*�����b��WP�y���9{kp�V�f����o���@cB�b���` �f�o�)��eݸ�f�@���φ�=;��?��v�����;��Qt���(b�T}��^�d? PK    �{?�����  �  !   lib/Statistics/PointEstimation.pm�X�o�6�l�Wխ�֎���4P`h�8V,�'KT�EW��e����H��p�����V�~�����(L��\Q��9�|z��	=��Iir��Mc�z��g5l>o�F��izT|�s����q���Z�_N/V��>���W�0<�xy����-P��I�L2?�m��K�32P������e��R�w���S@r/w4�!�y~�z���0f��*�ڃ��*�e*w�f����/M��'�G� �ݸ���w��\J|�)�0�00,��y�9	��s�g���"�I0F��n�����9u���5ɲ4kB�u��'��ˆ �f�k�|Q�A)v;���(n*��ۚ���<�M�$�f�y�������blȷa�i�i^��9�2X`��C��09���d��x~z1��\�^ p�v1N�%�$.f�����s�a��cq��'Td�Y"LY��=��xWP���w_[�Hw�,u����xa1�����r&����%�t��V列	����ּ�	6*����X��R���������i*��46O�ұf��Iӥ���M>u�Q����)�OnB�z,{�EO[^��V�_:�&�ڇ��2n�p�%�ҭ��c$�:��C������pM�������#Z�f��2��VC�tڞ6�FP:�	��Y��6�7���3ƞt��84u�K���*(��jb���x��F�5��
{����	��o����㋋�O#���X�`\<��!� �w��Zp�&-u�=��k�	%T�(���LVԸ�t�fT�*^ h�˗-�r�/�'�9�+����4F�H�@DnHt E^�QtG�c��fpt=-�_�xT����P8���bc�c���=1d�\��e(�}���du97Ǎ*���k>�B�R��ʇf=����1Ҍ���,�&w9�Ў�ƀ�D�zx�JA�?�.�&�e_ ҂b�����|Uy&SFC�v�WE��@��1��nr�/4��sH���,!e޸�+���@�ja�����!LZ��~;5�fK(�|$se��ָ����z;�i����\�:�'B�	�����E�V@d���������T*��&�^Q��5K�|�g1+G[��p�m��[�_0��b@Ã�NΥ��h3���9[0��:��<��䢳pѻ�O\���Cǫ�0~IJ#�n�$����1;��)�u��=d�^!�ȧ���)>fA{�b����������S�/�Ñ����+�C�N�;U����X�����m�i��jiUC��4"@U�޹���y����� I�c� �[���FV��=bߝ�WE�I��>i�Uŷ`��}�ݳ�z�k�����ܥ�	�&TLި�z)TV��
����[�bv{J��};�tV]�il�]���WAz�_�׷k��6\[�Z��w7VܾY�owSVk�D�l�:�K����}�B%�f%�+��N���$P�]�ݦ�lk9�+�X�bU>��x��tF�+��}s�᱆<��C���Lh�a�~�k>�q��f"��~�L)��L鈅V�9��g���TX�n�~���'1z��;�$�S��~kJ�,l���8%�z��s�S�� ҍ�Ə<P����$٥��j���0�j|z�a�קN�k�x������o�PK    �{?}�NC	  "     lib/Statistics/TTest.pm�ko�F��+&���d��� [�[#I� �:�}�+`@G�K�g�T�ˤ>���}��KRrܦ�N@,��gvf�y5+i1K�e��n�l�&E:�I����K���dIgWW����j4\���𖀞<>��aI	PV$K��mX�寏��-~
��8��zq���g�=����?��޹�d�.��nJ����E��b�"�������'{��U�̇��`�x��p� �ㄤ��p0���OpZf�'b�C��:%�G�C�Zr�%q��%7x8��Ђ�H�-�$�IA��谤Â�0��"ZD�s"��&E�[��S��ʬ�/�%�����-x{����!��ا��,3�ii;�m�Ѐ��6g�t`�~(+�tq�����	�-!)����_H�X�+Z��=P4*���~8��d���q8���EmXл$ƅX�)�Z�!�8U�ؑx.<=)��$�$�xT�B�MJ(u��D�@������$�|XI5�<ĔYX+#�)MBg	��>
S*)����M��~\�\;N!��<
㳋��_��ӓ9�S�p�
�E���C&dA��K�aM ����B\fK���3����V%epC ,���;N�Pz0B��ji��l/>��
La�r�YD��.�33Ӝ�|�%��,!"���j��Y��=��Ll�[C����9�n�P��%����ˌMF�U8�W �� �̣An��u[���>��� ���O�1������䭠
�΂��sS�����RE�V�`�	�	�Z�d��PITG�T��@�1��'84@f ���{4�W�䰝GN/�e�hKU�x���~왯�M5����jh
\M���o�"Y�Q��՞��L�KR9�3�LSi,Ӽnˬ��`NG�^*�]*:o&%�$����o��������$(�ld������+�f_7�: �w�^#6��n��l�໙��X}���L���l(���7T҅c�f�m�3;���[�6�o�f�^��\�㣣y�M�6)R#�YU>JѴqk7�?<�d˲�i�^��{!�Nǹ�������ƦR�h���-r����6 )%B����h�=�����oi�u5�
��U=�+7�]�E�mv��ƚ��׵���'A��CS��-txs��ڈuȱl�-�f�җNU�5�M�3���W�I�:+Yw�����^L/�o]F^�>�V�5��Os�g3L�)��'��8���X��;�z{}�Ӎ��M!�ğث����q�
��/Y2�y����K��,:�s��p��۞(�mm�Pѱ�����x[�r��ak�ڜlu���fjK1���f����j{�=p�j�y�i%Ƒ��cs�յ��xT۶�Ǎ>	�w�}ܓ
��� ǌ�ʄr�F>?o��x3���:5K( ����4��Wp��t}��_� O���K��گ?�<R��D�ρ갗���@=�Sœ3�Z�P������z$Cb�K<��������&b�
�l<B���?�΄���V9b�gq�\Z cR�0g���f����o%j�J���j�n�yỵ@�FD�� �:xX�����4m�Z0�����p\<�O@�(6a�YDń���݁�/���$՘��C?D1N3��<��1D<�k�m?�9bR'bHi��G1���rI�X4���@�jX'=�rE����Il��9�(�I�k�ۂ���|��aFD���ѭ�#�=?}�z�uϚ�d
7"�J�Mt��~j��܅�I}/C�k�[��n�,�0RN��FvX��+�i����Jt!W��j<m'P�,-K#�[YG�@�U]#�_�?lV�gSm��`R�5M:�ī�^Mg�X�5m�\s�>�6�_s}u]�k�i��\5���a_ߨ�p�=ߺ!�4PlJ�wy�F�J�p�BIqE�pt89�~rt����)3~=-��A}z(��:A&־ƾ/�p��F��^����'��d5F���E/��^1�-^���J��f��|@q��&e���"%�0�yqĬ�ox�52����'&�7������l.t�ٹdE����a���$Ѵ~Q\�/���2w
��F��_^]��"E�Q'�b-�z/ı+��Ի��a6f��#���6E��"��=VtT����*�"�.���}������QQ��ˣ�9�d�@�������o~H=>�l�=�v^R�py��9����F0rՓ-������T1ԓj�hK��2
ɦG�Ǯ:Ͽ�؎������{�C��F��۵�e�7]�<��TU�kB�V{��qYo��rK�C���o3�70��6���%������T癩;ռ6�3�]�7v��@է��������/;��p�;PK    �{?�e�  �     lib/Test/Pod.pm�VmS�F��_�I�mp�����'�4�i&t��Ts�N�Ʋ$�N�o�ދ��-�L8�˳{ϾH�Y�SC�/���E��u�W�hE�p2Ai��U�,�>�k�7�^Q1p�~�v���0w<z��m,~~�ߎ�����J���@�>��L.K�g�����h�C�Jy�h��c��sG�̅�)��B�;0�E*��7<����%����b)�U���z�﹆����)�i���ե�#ux4�og��Fxy��
嬑�1aWRu��|1'+%�"U&�>L0ʥ�G*���H�����Ӝޢ�Ws@��	�t�4KЁ/�kWK#�e��\�Yj��)mR�xps�AY�a�
��iX?��T��OǕ��0.�	w�Fs�`��I��m0��uԆ�������[�8�g���6(3�{���CH�8X2��MT�{,M�(��4Z�%�)Vp(cD<�;���,4�0**���f��u0���y)�e>'k���V��_�Af�*��&p�`!�����6W/V�l��,<�k����� z�rѷ��;�F�L�N�Ʋn8�X`"�(+ʪ��Z�F���>|Q3$�m��^Ʃ�ѫ/�y �S�k�&��
9�ysm���{��p��8}����,4�#�r�as#����XIEE.h.�������k��i�*o+�Kn���ڂ�êZ���r2=u氁����@�� �X�}�m0�:X!�k#O�pB�!��������:��`ML3M���Ӵ�X��������\��0���i.��7�6�kj
kR"1��E���>�k _
<��l5�jYs�<���;�9�%JI�lW��xXE�h���*�i�yjI|r��4>~�/����V��l!�|�ַ�]��5�v�ڻ�ش�W}-��YY�H#���YQ���p��<d#�w"�n�.���Hu���fQVpZ+:ۻ����V�UyKX�����g��ʾj�)��Ly�M�i]���Ę��o�f�n� v�����[���I,����_Y�����滈�	��;��[w@�^t�n�Mo�Թ��u��u��y��,�^>]X���T�#)A�o���2Q��;�ҹzc�y:z-��L:�~Oخc�j�������w�(�O���0�׏��?S!���Q��r �kM�����e�C�mO�Xͤ�}"y\z������ �1s�\���JB�����px�G�wx�w����]��K�_PK     �p?            1   lib/auto/Algorithm/Combinatorics/Combinatorics.bsPK    �p?���-  �p  2   lib/auto/Algorithm/Combinatorics/Combinatorics.dll�\	xSU��隶�i��H�e����	��"�R�MɳB�Җn�	R�-����RuFEEqD�ȸ .���)�.�:ʈ+�s��ȫ�k���w�&m\�{�{������s����������.��m\8�qt�|���R>���u�tc��㞌y5c�fѫWUV5��k��ZC�����cX�2��u��:C�R����ܕ�)��E�c/�8#(���'�.�O��e~�f|%����'�Ct7%��}yUY%+�����q�4��ނ�
�1�ˈ�Dq\']��5S�W;���z)7p�d;Ja����*��������CA[�qo�m'՛�����~�����MS���[I�=�]��8��Zɧ_���ϖ�8�S�lW4Į+��/�(���n���?��P
�P
�P
�P
�P
�P
�P�_H��V��Ֆ��J|^�&�\L�y�w�����յҷ��z�%��$&�����Y�a��
ԮI(����̗tX�>��&>�NŇ❔-P6�Nj�5��U��$�ER���jc+�����	6U�J�+Ǫ�W��,[&X�V[���uX�į&2#�^�>�������K�j.��ȵ��'��?1#�>??F�����D��{�ۥ��cTA���c���ڦ?��Q�Gγ���ð�9jђm���w�y�j��jr x�҅e�y����7���{Y'�>l�K�l���.k�S�:Vj�]��mT�j�D9����iL�0�	���´��^����e�g&H�;k��ͺ+������Q{
͖���l�9���nvK�W���K%�)�!,�i���/���Q��>���]��-�ir�ȣ26��tXx�.Z�
L�8&����U�ϸs㕶�~g�b�W���������c�~{���q4H�-��T߷ o�|�{��9�Б�����Ѹ�b�I����j��8��kas'�:l��&�� �$�|^�>a��Yx�lluC���MV���Ŵ�f)��`��x-N���6�(�<�WK�,d��b�ͪ�&�J��g�jE��t��~�dFX�mB%_R,Za�rᘽ�����Ol�)V,Ά6�i9l�i���G���I,�B��_��ڜNKLԀ>�	�ʦ�0+�>8��_3��a�.��&�G"���G�
�X�4sK�&^X��ɫ�-}�y�Vb�=��=�f��R/���&s�^�F���U��AZ��@3f*��<VnS�͆-d4�᪕��8)-z��:}�9���8j�3�~b���-)oC92n�-�OC�=N��A�_K�`���n�y�w^\�:�w^\u���
�Y�w
t��"��@���h�V�AqAzxn,S>��oC=2Vq}x�X)�/zb̖����I^����C�z�֠��b��j=���z.+��
��T�Y��%���[}�$�6�Q�p�2�1�:L58���0C��M��Y���'��W�y���E���A������p[��㸁�e�ay�_�q��[��'ly��5�Lk�Zb/�մ��͍	�R3onL�B�3(��5`�y+=rh�m�	���]�[!���a�J�CPw��� �ϳ���Ki�7��i��~so��/�[�m50^m�!+���`�m�Z��d�Fꏀ'�Ժ8h�1A�uv�N�	ޭ7��8F��y�=c�nER���d'0�x�7�}��%e��ۖ�HQ_��e�f�tR�^X���Ӯi�a|ڞŵp�r� �-՚�i���E���m^�	a6��c6���a� ��v����wJ��t2.!˳���ъ���G$�y���`�����SM4�������7���`~	��������>��:�~���oz×w�--��<����I8��-��/x�uq%\����ؚ�=.X�h�Ќ�:��6q������M�ӣp����=�#���у�p�QA��C�v�
>��U�?�%O������W�Zz[�;ZzYQ�4jHǦB�ڱa�"՚5�_�˫��������q�Iҽ� �O޽���LW*���t�{���yC�����!=����`=�Z�Z�%����SZ��O�c����f��[R�Z���"s������g��:��/G2��Ҍ�!���=<Ri��o�6������Ne٫sZ=�/�Q_��I�P��B/����������hb�$=�-��9�1>ʘ����P5jS�KÛO�<z;���#�m��'����W�hv�b��=�P��E���=M��7�mi�4�mMdQ�O��T��?�X�UiC�V� -xצC�V9X��[���ԨF�]��g���N�������E������׿�6���W�v���R�;/^�
�{��Ԁn�Z1�!H�C������2ULU��~3u�Ë��;��t�.u���#��Kڽ[�ܐ�{^�U�k�5U���ye���6�f�B�&�|��T�3�^fŋ�I���w��<�~T8|j3��\��`eX>�����,ǧa�{�Ш�eۈ�Qo������t�r�_`>�����%���f&�I�S��qj5��ߤ^�������e��/�ԁ�l��R�jvoMQ�谥l���䯅Ẕ��Z	eYJ�~]5W���Q)K>�N5�>���/$cLZ�P�H^���>���~xGr����s�w^��1�w^tB-V�/�,y��?5H��@I���k�~����:�Ꮢ�����Pm^~J��'�m�E���� +ihGo�rSR��n�Z�VR	l�+Y�C����p�¹�*�sa5K-58-I����V�Z��=�ʧo��{��sm/}����-=E6:��Y%2��¯�!1��g�>�Z=|�\E�����m&��=�)I�M�g9�fy{u���F���[I�h�VI�[|�h�E^��9e$��P�$�:�%�b�����1Me�j=3ɐvP�SH�WL���r�/�σ��\��gR�f�d:�� nWK��e�v>a�z�3?�A����Ŷ�������b��M�
���uh�y�6���wF�)������6��3��|N���t�-�*��-L�eA��O���	S��a��m�9j����'�"�G?�J�0(���A�&UvL��5��|~���)
��G/4�ρ&W;cO�N\�Yڅ��bq�H�XQ,�e���b[g��O4�+Uz�06ߣ��Y �1���1x+�~A�\��;^��3z��a��' ��G�Up1�~$���}�_�o��~PԛA���z9����Q_�z5�y &蕨O�����΢W�	|��?�_'0�YJQ��7D�=�)����pB@��j��{��'�Q�x,ap�7��J@��<���p�&�:OQ]�z�*��>
�%�t��@�5{"h$��$�ot����00�CHM��O2h��үS��q��S��^0���?�gu��~@0��1K	�Zj�U��s��"H7���M�Y`G�F#�e:e4�/�ɣ�P7x4N��d��h| 0F�?G�E�~d�f���F�W�^��6�~2~�X����k����j�g����,��x��wy�y��x���3�YJk�IZ���������A啨��./G}�ۼ_��`�R�����2�x��/'�C#���T�e����$X9x����Z�+� 
x���D���8��
����9�&�.�D^y��#��?↮�]P>�SG�V����ܼx=��q�CT�8e�V��?D�1K�8�O������a~/�^'56�,�`���R[cF�XF��SF�K�Iq�h}8>N-�t��::V��b1Py�@=�D�:P��O>��y_[-��˱DRō0{Jj�:�c�qZ�5V�� �b� ����)�� ��q��Ձ^(�����1��$F�J�O�jb�ȼ�+G� �FF�<�M��N�1�Sx�#1�7��������b���rP[Q��s�[%��!N�T\��	�J�l/�ό���~E�� �mn+�O!Z�NW[;=�����J���U|
�[ZDkU�� �'Z9Z�~���k)ZA���xR�?�V��S�#�h6�j��<b�V�G)��ڀy�9M�̣����<� ���Q��A�i��� �GΣ��>��#�p��f�Cу��#јG+ ���G�6E�GFe���5�oł*�V��?�p�V��)EΣ���G+�� �Q���1p�R�G�݈��ߎ
�G׃��
�G� �(e��%Gk	�mQ��ٳ��F!\� �E��+ܲ���b'�EJ��D2��(�p5"J�J/GG>A=���!'�;!�9��	�s��3���ȁ�J0������"���,2`��,NPI_b4b!F��z"�~D���#��E(s�5�Hy4� ���V�C���������U}#�CCW5����U���R��>���)B��g���<�"��mgه�z:A��I�b
�r�u������-г��g8��N�(��L���ſf��#[���0�u�9�Rg�:ܿ�w�{7U�z9���G��|&6C��-R�+���/g�;b>�M�������I�y:����ˡ����'U��f8��FG��$1�Mvм/�����8}5W��X��L}t������|�J��6�b�1�}�a�v��%��|m���.o���9!W6q7
*~��.�wc�/a�	|�Q9�ʉ͐yI�=�B>��^i ����0m��U ���P���_���@=&��i���X��>l���S��}Z���D���a�i?��
�}�g�	�m?��cR�p�D�X���?�����gmT���K���yԙ��f����#�V��N_���7C�N����r�$1a�����bLp@xY&O!��\
!�U����p7�BخK/!��	I6)Be	F&|�1a�"�>�-N@X�{���>�M�(����Q.	���B�"��$��	�C'A܂�q�&���y.�@}D�ݗ#�zYF+�� s^\
t?{m:+�h尦i�O��9��8p'���]_�e��^�� ߆�F䛑oBތ|�+��#7 �D>��9�g 7"��<y�_#_���U�W /E�y9�J�5��{(
2���ty��"Nߚ�gw!^KZ[�F��O"�{Y�&�/�'���~:##r��+��}UF�����T����^���K��<��2�♅��>�Y�pAGK&���3ݧ�|�I��,�p�U՚���ڭ�Rk�|�Тo?�i����Ƿ�k<��Ay��g�*�)�Y}��<��\���&�/a��F�_Co7^Z���%EV��~�9�܄{�3���Q(<�·��g��[��~��+5Η�g-n��j��m�2C�KO�_2G�ԅP
�P�WO/͗��}]wеM�ޱp�I�z��9.���t-�����躑���:D6G��1]g��KG~��NW!]6���j��I��E�-tm�����>]��z��α�Q�]~���[���<ކ�ù���b�unp�⼍���+����j�{?;Ω�e2Ai��-�~n���c�F��R^_���J��k�ֻ�<��&Ӽ��5UuN�F���sm�8�k]��kp�=U���:G}����:����秗�	��.��n���U��i�]�Z�ǉVU���d��T�z��J��Z2s�].9k��&GY}����)�l�d6hM�\yf`�]�e5��T��<��.w#��6��]���8j���JCV��i���L&iI����4z��M'�*'{�r���b66�r낥K�.�)���VX
��+X��i�ӹ�����'��b��~��l����ܛ��(r�k���J��scU<�j���ƹ�����9	�(��:	�u�Ѭ��hG�jS���x��w{�5�pUo�6Vr\S8p��Z��q=���a�����eIL�Z�2�T�H&��s�e^w��܁�ȩ���	O��-s�;�964:��ε.n�l��q��s�q6�$k���:��$�hH��h��W��^n��+6�M�F�b�\����QS�H��T���\���0~^V�uUfW�:-�[�ZV�9y�_�8�=).�i�Wխ��h�^����΢F������$�p�ӳa��ѡ,��74"��L�PE���?0���m�f����55ܪ�
��v�����BK���9��B������,��6z�4��Vۼ�W� ��T5:�Ը��t��勪ָ��yT���Ҳ|�eQ�TŐ�<_�\��/m�9ˮ��s�2�u�,�ZB?�^��5���������9&���J�J�J�J�J�J�J�J�J�J�J��?��D�of����T?�ԥ�\��v|q�7�g��{f&�N�휽}�̎6���c��ɸѸ�x�q��q��Ɨ��?5��>�&/9/-/;/7o~ޢ��y�����<�)ɔf2�ƛ��������
LME&��Դ�Ti�3yLי6�~i�b��t���.�n��Ӧ�Lϛ���1}h:i���g�07�0��3�S�y�y��rs�y���?�)s��ə��P
�P
�P
�P
�P
�P
�P
���i��i9�ξȾ�7�TZ�ଫ�i�:3{����N7��5ު��R��{S��7�}=x��k+ssK��T�)u��*K�^O�@�Ҁ"�(��|�_PK    �p?�FC|�  �  2   lib/auto/Algorithm/Combinatorics/Combinatorics.exp�QMO�@��D/Ll����ƃ1&�`"�Rʭɦ_B��%�����_����K�P0��e����tG����hs {��mKtH��8���D?Ѳ�ɠԋ}1� U(܉�o��Ԏ��ג/n�K�%a}pP���<��s,Z�Ġ4 5w�R0�IY`}���y8Fβ�Gα����2!z�<T��Yv��˲K�!»n�
pe����9��I@�d
-5D�$�/#�h������c�tL^PNy�)��/7$�/w��uq�i���z#ѱf|f���ťs���U�=\�M����4���UYP�;��?�(%��q�r^��Q\Xh�e�뷶a�dc��F䟮M�f��QTҸ�ՕfW�(+�/I�6xK��.��/�H����PK    �p?�'�A  t	  2   lib/auto/Algorithm/Combinatorics/Combinatorics.lib�V�o�@~����"�BeI�qZ	AB�DT'��t�����(53� ##c�Ν;2gb�.>�N�^���ww~��ݻｻ󳗭Q��J��ђ3���U(淢z�oM���T Hȗ �1vu��ؗ!B����F�T��4��ͽ�qm�c�sGN����<>GpST��a}�T��2�sh��)�O��dָ��;�C���_�$x)���#��4�0�H	dH��G�;0��e.�pAL�3T����#5b9���!kDG��M+�fK
|�[���0�i�0�pc�P0�� 
j�6h�k�t�۟N���J_�bJ���8ݖ�Z7��	�7����
�g>��U��njO?Cʐ��.�XKg
�r>�WkNg䞺<}��B���݅kx�L���iX'Yo>GJw0DG'z&>+��̄���|�Axe
_�I1��4�<�*��uD���;3��s3�2�?�AZ�1ݙ��2&�u4c��ጥf�m"���}�jl������\�֗��*p����x΅q����0��� �b�\��?��lK�����^kw�����(�ԃ��� PK     �p?               lib/auto/Math/Cephes/Cephes.bsPK    �p?0����W m     lib/auto/Math/Cephes/Cephes.dll��y|M��?��L\�A�<kjVS��%"b"EUr�1EWEQU�ZS�sb���*7��z")�)W������i?y=��?���YϽ�>{?���>�Zap1����B�!�����������j)g8X���N}�=0j|���)��2b���&}�;r���$��|{������1-ʖ-]O��˄�Os>(�ߩ����o�����-q�8�;;h���rp�{x���/������Ə����<}�\�:���\�2N%X!��}�Ѓ�{Rg=q��y1Կb˓�A�O�_����a�k\�l�O�������>�M��`Ά��n;fz,�[��(����?����0�Ŕ�#bG�{�4�Y΁�ϟ�ׂ��ve����A6;襴�2f�G���Uy��!�k��n����������������߿����������������
c�V�r��8�YX�5���Q������g�O���¿�sl	�!ӐS.H�ՒMj����Y#|��g�S��L7���?ӧK�Sz�6i�5��	��o󄢔�����}��PT拄&+	M�Kh���WB=��^$4]Ih�]B5�U�z�G*O�xB���%�����	}�oDBK����%�Z��+��P�	�PZa�Pwhu���|��%Z�$��.���"-��kB��r�-��f%��v	����Jh9T���+	m�K(
ZQ��P T:���)	�K��j�WB-H%�O(YI(�.��Т�&t *ߊ�R��R�J�V�%��"�4%�4��z@��%T*�DB�JB�v	�nNZt	��s�Ǐ)0��Iw��]�~�5��`4w�O-H4Jǁ] ��wOrM��4/��s�g�e)������F�

�x�u�4�K��9HZ��+1��������$�ĕ���왽�I��ӂ�
�\��ꇂV����(yM���r�~R e�怂��X�L��L��O3
)դX�)�+�&�E�T����)}�d0DD��,4b������P����gi��r��D��"B�m�������V
sO�V����y��Mm^���f�� i:�76#��̵7�{K#�.I��5wwg�v�-i6��{�T�f,v���l���4�J����4)4y�J��s)��,���B����a�5
�0�':�J��6�4����/$+�r2�`�5����z�S<UϜ�O�+�DO�A���h0��TO����ϕe���O�̵�����ӡa���<
c���y���-lJ9?�9_�b*g���"�S�i^��rnӟf����{{�{z�DK�?�N��m���Ӌ]�8�;q�W�o��V)Æ���]��ۈ��h���̓$o<k�6� .�!�s��ᙿ?iBA%����C���������ߝ<�}߬�������V#��&�O�����{ɨ	,�9��gf2#�(��#]�4�8DL��'��&r�����U� �m��Uj�ۖ����T�[M����7*F/���W�6�W_����6F��T܄ 5�Rq
ؕ�EV�TPq�Ȫ���k+U_�LE�3T��h��`h�k���= 5�U��;4Vh���X��nl��������׈ cc��o'�v��Y��HS�U�9�H?7O{ �4���7��t�o�Ӗ"]f"Nl��e�k�e|�2���\��H>�ʳ�gBh�H��*��6r��R]��}�P�̯_7T}��)}Q��Ho��L|�gƓа�H[Ɠ��<i;��4%�C�������>m���cIk�В}Ҕ�����s>�BcDCa��p#��@�(���n�P�,UP�!z�Hc~�@ٿ^7���r~<�߀>k`�^u�+�o7PLr���r�Kf@:�� �J��/�fOi��&%@X�@��	�|��.�\���/��C���6� k@�i��~03N8���٦5�#W�V���=�g���r�X؋�e�k@2kI�l��v���'`.�� ψB�{�_�t����ݙ�t�X7���R��:,,�/�-j2�A�)��ş�7�X*�Z�fI�J	�pA	���xu<�j�˩͂�"�.���ݩk���$��Z���*����T=����BS�T�R���R%�&Ĥ`7��H6�ED;���R^=������!vq�I�
 h��S�ጦB?
܏��<�0�5eL�EОz��>���&`���H�9w�c����)���K�qXM������B�����ί@*	�V=#я��tr�T���u��~�Kqr�� X�j��=�u�7tU����PW�6�P��ܱ��`h�������u��j n\W������P�y�u���>�Wu�� �H����t�N���nD:S4}	a-Mf`��)��U�� DZG)ʌ�T��g7�h �Iu��T�P���֔�\��co�6���*=�m^m�����joЈ=Q��'�T�"<f��*VC�����y���.�B�1�1���1��U��8N7��
���u��\m������W��6�+�E� N"蒯�2{ ��U\f�4�/��F�"]f"��O ����l�o�F����Mղ��Su��q�#��H�_��o�Ւ}���k9��Q��Uڇ�c���l�x���3bcp>gcy�"G� �"�Z�$��� �_��#���Q���⟚��)�p�G���TF� �P���a���i?��
toM;��+-���b�Y >��/#�\u�ƵI�!��)[��5���2�x�Z,���5�m� ֨�A�E1�x�������k5(Nv���5�F��X����4�9�52��S�st�܉rX��;��҉�`P��M%(x����&�?�~�7��w�P�.��|0�)���G5�F	y��@9�Gר|����}���W>JA ��!�����pbM�M�!|`��}d# y��E�%r5l��J�q��G��Ė>j5�L<�ȃ��>K��6cDeW�N�/�d�2 �T�ruص�v\%��t�p&���5�wg�3ho�.Xi/Țx���6Ud�����N9M
��`e�?d��q�R|���Rs5�E��	%���<!��L�+4�;��^U#xKu8��\?��%�4�ٚ���Wos���&�!t4"x�m9.LE: �u5<��WC�K�Ȃľ�X��KY]����x�b׹JӁЕ��ڮ�M�1�Jr���O����GУj���;��7������̀������<�(V%��x�{p.��Պx�5MT�
��A)U�f�i��C��U��K��,��:������+������I���V�;@sUԓ�ޭ*�If�z�/�fU�Z����+n=��J�7�e��JB��A�%{�@-y�m�59�Vo�&?B�୭![���.Vk2��u��0�*�� ��V��@So�5y�oMj d�7X���-�&��r5�ɣ*�1v�����*���VQ[�3�Ӣ\�t������?X<}aK-O��-�R,�>��*:���^EǓ/�fUT�p��� x��2�t��$��e�,�Vv��B�*���ʂ��!���OCs�Ӫ�z�b���2xaFe-O���U.O�ܲ��'��+�x�U"ص���� �TRy�]���B*UO).W�y��X%G��"�����U<͆����S.���1x����/�GWO]!����)�v����/R.]I����������t�/��)��m��<�����ȫ�y���J�p����i �	^���r���]/=O����<U���K˓0/G��䫉�Tωx
&�~�H��+�6���@���Uԑ��ފ
Y� ,�(��I���y��r��,��,�р'+�H5p��j{� ���	��sMa�j�Y�(�jE��T@V���1ů��d���
� ޯ��L�;L�c�)�C�b�M���la�b�l(�Uйlk��tV��q�
� T�M����N>���2��|����E]�}�=V^��A<\^��4�x��������X<��0���� `C�;���l\v���S](�U^ÓS���ػ�ʓ��3�v���ܓB�x*T�P�qapb@A�w�4��ix���>��,�pϜ�,���UN�[Z�k����ꂑ��,9y�x���.t��? �<�b%4Vԃ
�	��A(�)��/��<����UJǭ�C�7b��f��O����7�
D���CX�5�G�fy���B����n��h����� �����/������逭�|!��)��t9����PNg�i����<��r����^���S���m��(׃�WN6�d�r���,��Uz���e��� ��jN^� �����{�|Y�+�j�؆��2�(O,�3���C�:�!��*��sY�@@��:?uG���B�+>������>�3�Z�_��<��]1�$ #���̇8���a�����n������"��R9�Vs.,Cbw��'����`��2z_A�Ge`�T?���;`��oT1��2E�*F#hr]8��b�N ���F��-G�G� W+�������Q����Ҏ���չ-�@ýl�#�ӥe[|�@iG[$!����./-l�\Z�-�)�߃)F�֛�;���)�B�]Zk�:�Z�.�)�Ka\P�Sd �R:S�|��b�� ��ҙb�oJ�L��R:SL <��b�� ��r4�Qa�И_
�h�})�>��r4�3B�*�4����)$��R�)֑)�ʄ)n�V�<�-~D��F�b'�cF�-���Xd�[��r5�7�(h�B����w�d�E �"�j��~ר4O�T5r[�I� ��z$�Rr�қ��Va�WKz�yI�^l��tHZIոh��PR1.r�-�%u�]xcIŶsĔt���.����h~AQ��"�DV���{�����Ȍظ&B�*U�m-R�s�Sr��S��؏���d��w`�g%����!�l|������;Q�X��(�,��O<�����UB�j=�SB����+C3�Ė@e��i	�2x@�.gQS�r��J�q��MT�;�t�,�Okn��nv�A����N����v�i�J �ҭ�
�
1@�Cy����n��td5��M!�*��n�u�M�]����E�F�c�������_w%�������G�wU}]�lA�w���� ��ՙ���:wn��U��o;	�\a�&����9�Uiʔ=�v�����]��j@l�Y�"�ݲ�M�Ү�M�?\H���˂��Ek���,.��U6A{�K�J<�>q�Yo��.�����Uz ��˽Js�\��[�ʀ�(�p��ٱW�țW�_�Qw\`��8˦8���c��!t����;ga�Uw:k�У�)��BE��opFB�3La���݀:��]˹S؜(��Yg����pRL�������uҙ�+�{�t�0��I1�L ��Mѥ
7E846;�} �9ɦ�����)j#��Re��q�(	���j
2E�/0�_�)nH�����jК��S��b	�W�0�D�0�L
x�A1E ��)Z ~Ǡ3E�u:S �S<-tb���7E��b��0E
���*�!�lo����d��g���_���U6�@2E�|�YQL��NXb�-1�@ꎈ�)6��Лu���ȍ�&���b�� ��ɪ�o(ދ7N2�寫���X�rF+�����P?/ԩ�M�_H��X;_h�I�+Q������=��7Āg�_N��	�@�Y,E1\93b�@7D�xZC��Fˀ/�fo�W�(^�?
���P��a���Ge�^��������^��D��Ga`:����-������+]1�0�B��������G�y��@YM�.;0�#�O�d^՜��2��"c`1�?-P�
`y���lI�F�+�1� �Ax�@ˀ�F�+_S���
e4%8A��PO}�2p�����@�W�V���ʀ+�$�H#_�+1�5h�����j���_x�7�{��@)M����ɿU2~R���2�C�@<�?�[a`
���,#�]���W: b���@3]��2�����+Y�(^�+������g`?ԏ�R�uY�o4Q��b`>��^)L��ʀ�$5����W�!b�W`�	�N��TV�����]�{lSpӔ(ˁ��P?jS�咪�]��h�s�o�)L�Ȧ2��h�b�W� b�4���Mˀ0_��ʀ�%œ^*�hJ5I��wP?�Re�狪��$��8�'�T� `�K�oIjpz���B�>/�@�_j� �������/(ޣ
N��90��?�P�vA�O�2��j�,�/~�0`�����@�K` �ſ2�6"��ԃ����O`>/�W,Q��)��%�����P��/���}��4�3����@�y�4b��:�@�_���[���/0PB뿴�V�������A���?���N�3�-�����O�2p�<c`�������2��� ��+�1 �Bh��e��w�����?)^֟
�ϩ%Z���6���Se��F?|����Ā	���T`��*�,�T3��_h����5!���e�4����\N��>WxuV3��X��V��}�2pA���e`�'c �s�+�0��@1�s=�W#b��`�B��Z�������?�x�g
/�hz7�@��g*�5��?�0���1�1��)0���@8�$U;>x��4DĮ��@5͞i(�³���+y�v���_�����g�K���S8�ѷi��c|�Yy
CL�S�"�ς��yNv�
���CX��� O˂�{�#.ˮ��4�B�iO)ލ�
OO��6�B�Z;���1�z�q�JD
7VK�X�OQ��2���oˉ+4�K���V�����] �<%���dO��w�O���ߞP���;��O�ܝ���X�i��/C�uO����펱��\B��OT��j���;���m���i�{��s��,�������# o�P��c�ͧ�ݍ?��������a�Z� [����]��C�nZ��ݐ�"���M�P�둢����{�K���yi��u��wG�|���N �rU�ѩ�n]�r7�r��pSr������r�x��
wO�ܹ����A�9*wƓ*���;�	�8֞;�;�Ŝ�� ,�Q�[K�>���O��F��r��B���/0����;�c�����*wǊ�����������ˤ�n*�<V�ۨ�h��q�Q�=V�k	���*w�,��{��>���78TrB����_��@z��V�1(��)����P��{�<Ʒ�W���<�k��5���As f�-
,V�� ^��$�@O0"�I�[GB/��X���� ��U\l\7�A$H/WT�!R��2����d��;�&HAIyAұ2�Ν%�&Q�f�H%J��#I�|Cr�׹�̝�g���� ��x��^%�Pg��W�{�$�U���WI���>	aF/V���$y�*�a}$���y��8�m,Ut�+ٿXQ�;}ε�Z�}�� [��Mʄ����A�X!�s���w�B@Win�0Z�����b}XNŨ<rːcX�O����Uz(bO�U�?�Q�k�tg`����a���Z�fG�*�djC��Q�{��*�갦�N�a�B�#�J_���N���K3�&#��GJ�`�#�J��xRգ�ҁ���9����<w� 4|���	X�G�+w~�x���p���r�~Z�}�[S�;���?O�s7�1���%i��uܵ.Ÿk�(��)����7��c�]�apW������C���9�ܝv����]��pw�G�;�(�#Ƹ�*w�T�8��]S�{�r�_�?o�=w^FƝ�W���P��w ����M`�-���_�����|�Wp����j�K�������������C*w��]-�h���]�!������=}@����U���M��ι$����=P�����;O�#�[��_'�Sq��6´Z���|P�u9x["0���暈��BY�jy�f����I��I��@���F5k�f�z�+���W�} ����T�2�{�!�{�}m��)�y���>J!ᾶ�À}x߱���U����}��!5�N3��[S	��[N-��,J�����������'��!ҍ,�a/��,m>�mVe�X�V�Z��F"�,�,�Բl���PYf��C��>+�v-�D�-U�\Gd¨9:Tp�B�*=��?�D�� ���ԝ�eD�ƃ����E���@��{|�a�=�������՗ �rO��}����ԯ�Ԇz�{�K�����иt���.�Wq�, ���K[����W��Ue����v�
ᇻڂ��E���hO���HO�+��~b8���w�j�p����HI����1��L�B�n����Le���X��1��n���7�x�	g\a[�쌉��d*�g��G��4��3�3�@���:�pfo��{�"�g:�N�ԇ~�L��B�L�)\�yfY-��5oYI�W�L��Ԥ �l�Ya����XfU���\9Osr�
�>�g�yy�UdQ�S/��U���V�Ss�V��������Su����~%+xʃ�l��d&�)O{�|􎎧u�����i>�;
O�����4L���Mw��{B��<u�pǑ�Z���[�;�'7�5�h7���^���m=O��&�?n��4�oky:,�v��"h��]D��A�n��x�m��� ���U�f�����]	pm��� ���j{� �3�v	a�KШx�8�b�l�=��d8V�������5�3!��PM��L�zL��7����St��/Ck����d��-�]2�Sd!(ע3���XS$�mљb��,:S,�֢3E��#�ZMQR����Xb�)ZA�j�MQ�[GS�B]�7�`�0�S�%-�)��;v�����8	�[�`��!���5�&`;o����q�t�� �co��p�[�ZhpKm=��<y#d�-�TB�[2O�o��r5<�G]���}pS�t⽛*O����]�釛N�3�~��7D�C��I�E����r5؜�2W���sMS{�ڜ�mΉ�*�a�.��vE�>7���z�c�,�7�
~! �y�-���^	�E~|_��z�q�~Q�X��|��҃�,��� Zb���c7�͖��JiX�	�#�D?i�_8+��-��B� ����z|\����g��M���ԕ��P�"B���W��r\�����=���A��=$�U,v���Z�4 t�E���`�A`�����聆'�GP��R"�k7�����eC�,z��+5J�@�����Z������CP���^������PQ~(sz=4�g��~��.�BW�P��sK ~h��
x��C,(ǗZ���3��2�~v����S�.�Yq�1 �*��؟E��q��j�{Hu�m;�^���mTu��mT9�?k����	+�s�ڨ���q]�F|꺮�}	x�u�X�,���Q}D[��c�A�81��6*��mTg��Uj��.�Ou!v���d#�2�O��y��闹�A�]��t��k��i��_����k:������4��k*O���/BV_O]!��&����y���J�q[����u:��5�'�Y������t=O���k:x:!=]��N`�ҋ�S��u<�<%]�S?����� h���tH�T!��Su�e�J�2�;���U���*=�퓫���!�\Uy�%���O�W�<m��ѫ�i-��W�<- ��j�x
��:�� ~������[]Ux���U��x�S�
�q<=������=�9Wy:��JGp{��i��WT�ZOc����W�<͂��W��$�hyl�G��p�.��5��l3h���!��R����(����?a�sE��1 #
��l�h�g��~����� �)���6��RF��,�I�@����M0A�?� L�I6��Q?��{jL�.B�*��m���	A��I�����M6��6����//S��`��
.kmp؃����P���WW�tY竳 /���`�e�Wk�qlB�]Q�!��,�
r�ˎ�Z!t����eAT�%��/kVU��Û����<]�����)7.iy��ȥb�4�I�t<E�zI�S0�a������ʓI�S#�L���ChxI�/�%G��]��J�p�����ħU�&O+�Og/�y��'/��v_��ت���)�c.����?���$�x�!�/*TU��w��	2 �}<�y���2O�B~z�gѨ��B�*��������_PyZH<�������i.�?� ��@XxA��P`�y*�{!oC��O� 7��ȓ!����P���^�M<Hi��9	�����6��OI{K�|�����l��(� ��cOQ`��<XN���@�4�U�-��o�EhT�[B�4پ.�=Ҝ���S]���}|^��*���k��d�%a�c��ބ����+!l=�5p����2p���������������켃��:GN�u���9G�AH�9�� \;�3�F����� x�9��'�yN1p$����<T��]���B�s���@nq���F��U��,ݖ:'�b�s�&��sVo����Yx�Sg��l��b�#(�:�3p8��g�!�U�@���B��Y���9��u4�yzF1�u ygt>
���������I�ןQ<��3������"��30p�gdw�x���BW������X����g���������z�"䟆��B�Zk��Ο.VW��N��i��O��߿<�b�~ ��V��4AT�ĝQ� �>-����EQoNQ]�?q[xJ�b�)�+�O�>O�O�y:�˧�ӷ����)�/O���P�rJ�S?��O�xj��)��� ��Ry*+x*���S�� ����S^*ʜ���M��U���[���co��<�OSׂ���vK���3"l��8u8rR���q�bR��;���*u�^�T�G�����
,h*�F��)Y2 �O�K��`�-���3�S(�1�[��R��O�trz�2/�cW;BW~p���Z`�����5���N�.��"�B��n�&k�)��@��f-ڶ�
�O�b� n��T�o�;yAl����\g3;]Y;9�����I��I��-�'�6:���"���a�ZJþ�_����\��:�{R)V�>'u,������/�4�F����!���KoN�s�I�����Ԗ{nx���	����|���t;B�*}��'��C��Z[��
�?�f���->���`:!ז@��Nh-�X�	;K$��������-�2ЮrB�_�'�pB%���}\a�2����<�|�}��!1�&�ʳ�7!l?��M{i�u�yf}���&�5N��|�	�9r<8��Y��ξpr-�$:8���{	�UŢ��������(�+��=�����������k��	o�`_t�1ų� �U���9Ǆ���8똦��#_�Y	_	:���-��c���!�;�����j+V��(F;Gu5�'�Gu5��SG�rm����%��uʌ�����9����$�3�:�@BW�=܆D�q�Q�N� ��?O���y*�:G��?GH�8��)�_G���1(�����#:���pD�?����<�0�zBvO�F�y�	y�G��!��Rm�6?"x� ����p���r�d8��S�?>�n@xtXKT
�ˇ��;|�n�7A[�U�i�?��������������ʮ���x�W�n��b����H�v��$�<Y�XP��g���\^���"�G �KV�� �HvظWv>�s�#���<OQ�)� ���Hȓ�EK���]o��U���H��j�b�dnc|�.����2~�'���?R/$ =����5�`��X<#��?a�U����ȳ /�Q1r4��?�Fy�:#w��G���o��j�@���3�3�r?�9���C:#���!��g $�w#�AD�����I���9񐣑G!��R8nGF~�C#�&#;�a䶇FU�-$ ���sHk�?�|��Ȯ���#�ϳ�p�"�A�~���S�_���y��?p�<�'���D牆 �O����D��-�e��֕��%j �O4� ���J� ��D��S����z��	��A�}
�˃�- 0��ƃ���\���X�C��P
B�u�%t���M�+��t�[��˽Be��U*��*E�Pp ����+�&_:�����C�q	~= _:!��֗v;t�x�lh/9P�#�@��:�8�b� ���Ɛ��5 �Ta�`��=�%��������8�{��(������5�}�+���������P��
㡹�{4C D}/7}!���`�D]���m��h0�!�}�i0v���-��ݾ�3r#f�G�)ƛ��$�q6�&di?�����_`W�+v�׳�-��9�����^�g��]��jho�/S��� '���x,�)�� xo?7IV���X$H�K�X`v�?�^M�����$_[*���JHak���>�s�����t�p�}F���%�T\���'�	7�g�� Y#R�Kj�������ӌi�x������٧{�O�Z�-��U����}�l)�>c%D���2B��'��m/ɮ��v#���-ڻ�+͊
��q����6�Z�_8CxO��S���^�Y�@�|��f��GS�`�R�1 �*��ؽ���q�^��:C�춐����p������*�w����{���b��r��p��S{T���?�w�Q����=�p�~iq�!����qb����0ȣ�8�;#��RK�v�#x�����,�)s?������w�_fxz��������~W,��Ay�w:���𝎧i��Sx`�w*Oߖ���;��B��d�ނ��;G�*!��Ri�V�N��z7ڂ�4������������n��AH�m��;��X<�A9q�������������
O] �ܭ��&x���	��Suw�<��e�����(����>�%x�b�.�'C�������r8������Z�wiyZ l��b���t<u��.O�ڥ�T@�]*Ok����N
�<=��z���=�9;y:��JGp{n��i��;U�<��1s��������N�4	¼�Z��ӑ����7�v{h��GP��:��ށ�o�BV6��������P�?�8�Q��X� ޷C� X���8�fql�ch�S��0y�l������,h7��A]��p�q�0�/��;4G����`�r;����N��0ů�ڮ5�U`w��[����"L�A���L��Y�S0`��� oי�p��:ST\�b
#��oMQCԊGߒF��0E�߾�Mq�/�:�b/B�*}��}�
S���ݷ�Sqd�~�a��o����oa�p��jM�Xз�3Eeh���S����J~�3�C�y�(����ot�88��)������o�F1E���q4�JQ+Cc�70�}#�����q4E=��U�����S��X����gf��m3��m��6��2��۴�Hvf[�f|K��v[3��4k�n6x�6e6�@�m����t3>_��TXՍ����3�_��k݌�����g|���ζ�>�b�- �|��3�'F>�͓_cta����|�_;���BW�n�}-f| v�Z3�NF�7F������Rw$ ���V��vok����a�Z�Ug��s�*F	 t�l���n��#�^[�F�������q۪3��_���jo�@���'�_)F>`�W�n���ȫ�y�+9�ʯd#� ����ȃBW)�C�F�1�+�: ��0r���'"4B|�B���6~��-�kTS��Ӗ"�o��]��	�Ϸ(�� S���q�c�(&�j�![t6� 8`�b�F |�86��*�F�4>؂F��f���Q͆��f�F�*B�*��m�fѨ� ��j���L�	�غYo�����a�f�)F���X��vP�Y7:��l��
� WڬX��%�_���-���i�<]�����S*䟾t��Jq��K�S�m_�<m'�zł�Y_�y����K�a�Z�:��e�x�r�/u<�6��������ؤ���&��{��Cy�	<���&�����mr�i.B�*��v�&���q�T��O�b�S�&=Om��	<5���&-O^�|7��߿ �?��������À�~����/T�ު�yZ���_������y�r��<�!��R_܆!x�1�͛���ˏ�S�/�<��~�/��B�/�<�n$̶�X<���:��>�Q��J�_lTx� v���`��X����" ��(��䐍�<���J�p�Q�T	b󍚷戧�����F=O�}N��|�,�����ϋ�*�JY�>�Ek�s�?W��O_�A�ǟ+\0�s�[)��'� �fi ��x �.��^z����4o�D������7!<� ����x�gv#����~�A�`ĝ4:ld�>�s7�m0fl�B�Ak`}7��� ���_�� �:����^1�U ����d�g���-��[�3�R�k�+F�`�z��E4�\[�!t�l�w �\��]�"��R%��^/lQb������0S�L�)���Mqs�?YS\�pg��? K]W�fc	�W��5�[��� �c�)Vx@�uj���>��-�L[��@h�N��r5<�>C�Ǯ��}����.���<�O�&��˟�y��s���-|��)	��ϊ��p(O�L��{�C>���p���j����Ss�SI���<������<=��b�#O���t���
�A��V��4�C���Z=O���i-x���V��`�-O��c���ڀ����Tp�
O��`��F��z=��=�4\��C��F���+kyڎ�J_�v���r�߬Qy�D<������y
��k�S��hy��5����>kt<�ZM��O ?Y��t��՚L�~DH�j�¡�2O �ڑ�y��d���Ղ���Vy�K<��OW�yj�V���:���T	X�Վ<�]��)����t��OU��߿FȩO��8����^x�����׀�X>�x��j{���j���u�	Z#h��0AC�>�MPr�O��Va�î�sܾY%L�+�׫4�����q�A�*��G���`�m~\���J`_�*������U:_�J�m��J�>���T_�܀U!��@ԛ�$�^%���+}�B�*]��/+QG ^_�y9�x�������_�Oq>Y��i<0��b��	ʽW�x���:����R��<[��4���!��J>���`�2��|}�#O�BWin�[!�� �\�y9�x�;����
=O#�?sx
�0n���n�W�'/(������'�Z�����(<���'��OG�<�p���M�w~���B��U��ۄOO�|�YJ!��O��<1��B5�P�B�O����=E�''��;!X��yi�Cϗ��;�� �Ax�\.�/��/	�RI) ��?�6u�(�7O,o[��b�(���T�YP%��� �[�-� `c�i��0�q��͡�a�����r���ᒂ$
1.W,���r�]�T��؇�,�y?'�?�Gȧ�D���j8��Y�3�nM�,��9I��1b��H�cJRى�*!��ad���N�z'ٱmC�������'�4̛nt2U�l�vU`��{Ny��'�T�\�Ph0$��J����H�q(]P�z������1��	�;L���2 ���>F��ِ�,S����,3!��6څ0b�b� �/��?(ls���ȯ�T\G�5�7��r�� ���wŃ�����,����Y�?��f1���2�?n��e�C�l��?���o����j0"}h�'�n�zBK`]̎�P�OJ�A��Y�>Y��o��9��ץ
�� Y*N�*?)�G��M���7�]��~Rz.��Ku֊���Z d�R�Z�^*��i~R�E}�]����V,��R�Y{�����<wV��!t�2p�[���E���9���p(�.�,��3�k�DXo	��Z����X,���rp��z~�;%�Wp�D�zF K���["��*Q�7Po�T���Dg���-q��
�l\�Xo.�/�8Zoy]n�Hhl[�A�D��?�K�� !t����a=w���hf`s���!�z�;�� �u1��/��B��Xk����/.�p���Cy�b]�4p�b�p2e��X�]_ ы^�n���r��>�)�:gqFH99io��"<�^���"ݜ�4ોT3��vN^���s �,���Zm>z�C��E��d���y�"ž��'B�*u�m�E¾� �X���,!�6mk�E�a���Pq��a�����=J(����������*�����$A1�� < Ct��W���k#�y�b`O -t~��`��� ~�Pg�K�o-T|�����������@�|�l๐�<!t��v�Ba�>G-�x3�5n�Po�j��r!\B��Z��G�����l�������!��+^
`{���?F@\���� ��w4�?B��+~@`���ހ�����l�����b�b� ?-�7�/5���.�|���e�y�G/D]��MX � .X�1p2�n�@o����B�Z{���XŜ���r��o�8k�j`�u����uw�<_�(�D�B��� *���2Q&���;N#��Rn��Du�1_��G<�Oo���T���'W��kyʛ��^�x:��t<��<O���[�)<-0}������h�|?<EB?O�)r�<G�Z!��R#ܶ�'x�
��y�������S�yz��璾�<�d��d���4`7���ϡ��\O����i"�s�� ���t[��.B��Om t�+�T��sy*��Jܺ�<=�Cb��*O��Ӯ`�to���T�g�O!����i3��s��S�����4p�O���Qxj�������j9<��Pu���?q(�G�~E]%n�	�.@���d��x� �~��������2��<M�0Α���߇vh��j�k�J��MTEH�8u��A�nq��l�����&n~����_��t��f�fq��0�g�7&X
a�l�3!/��K�]���J!�1[��'ġ�5}�/٠06h5[o�J��|6l`�Pm����0�]<����Y:�|t��� d�,����,�&�1Kg�P�#g�l�p�Y�Z �3Kc�R>�4xlPB�Y�^�$�y�����t��3�NA�=Sc��d�Y�`��3�6X�;f�!�����d`�g��B���:4�n���#��L� 5g�l�=��f�lp��:|~�b�� 6����Z5n�Otkl� ����@�3������ۈ�] ���~�l�2�����p��π*��� w:a��E���L�	h_���L�V흮k��^7]1�, Mם�x�]>S8b��m�;]1B} U�;����*��4�L�-^L��O�m���i��������۟�	[|��4�[B�����<Mo���0�0AX<Mk��&N+��/����4]�Yp�i:+� \a�b����=Ug���O�T�c��<U��<��!��*����T���Ġ8�g��
�!̞*[a8�	SkDO��U��^S��A�1U�GVx�>�Pm��
&���
+<��4Uk�;�~7k��GL:+|x�Ig�y���+|`�IČ��y
A�&���@��S{�=�,jx���Jq[�$xr��cRyZB<�x<=���t#��sc��y�Z� ;[,�AyU���� ϊ��xt��S/ cU���#��|!4��y����Ӌ
����ۗ1�'+���n�7x���i7��Ā�/!���d�YL�x
��O� ��x��)F���1*OIbY�!�1��6���'	r�G�� ���i�^�"x:������Ӥ^��)��G��)>��9a���a�>�b�տ~��mhw��뷫n���,�S������~\ė�N�r��B�
űH� \�����/���*_��p�)�/{-��v��W4BKL���W�/>Ɠ{C�'���a�?�Ţ/{UBW��^%��J�_�ʝLAK>����-��>��\�ps���e��@S&+�� ]�u��z�p�D�[&k-)�+��W�Nv�0��h��+� GL��J+`]'�Wܠ]~��W�|D���|��_?R|��#�+��W�B%�#Xl-��>�}e�U�|�#�U&k|e�7�+]z�#;_i�c�d�>*�Ws�H��'����+w �}T��� h�Gv������+� �d�+K������4 t�&�v�$�+�M�4�r�|�rw������o3D�1	�o-oO��I`U&���;㟉���<��X��>��&*�������Y��	�i"X�a�D����;ѱ�� !t����DATk�}'j�OO���:�<�B�g"xz9��R�<�
��b�tʧ&�x��	:�� ^=A�?�'h��'x�Dȶ	�)	2O���Np�B�*U�m�	�'w��&h~�x:�Ͽ���Ë�w>�?��@��PK�`�>t$���A{�u/~���[򋁃 ��P��-���� �xʋ�u �Pa�b`i��Ez��k���.Z�b�}�D+S0���[
*rypJ��Dn�Y�����/1p4S)j�4�t�C/�-ZJ͋��"��R;�v'%z1�D�h͋�����/��߿��W���1@|�1���Z��`|�*�(�0^WV�4^Wf^<^�� ��W+���!d�xT�����+C+�]�;V����T��Ƌ�P��p�Z�O�;�߿���t��G��SnDiy��HT�x��(Oр�F�x
<,J��] m�T�z�!drx��a��S^�(G�����J�p�|���ħ�T��O+;�߿���[��6@�=N��"`����(����]�����p�q
O� ���"x2 ��8���X
��<�
��XG�. ���	�^+x���Xͱm�i|G��c�<ͅ�gc���jy
,zl�xzʝ��x���XO.�=�*<=C��1*Oт'B|ǂ�Kn��y:
��G�� ���Z�~5F��c4�;C<u{�����)��O�C2F�S[`�)O��\i����1������G+<]pb������}��O[!�-��)�/G;�4!t�&�v�h��0��F�<�OU;����z�ނ~����֣�<�Vm�#OE�0g�B�8JC�~] ��(�(y�y/B��R����(�
�b���)ȳ�ɀg+��@�1r��� :�Ҭ0[�zZs�F�����M�	�g���zڋ�BW)�/G
X!����ִ�.���`"�	l��o��K��Y<�v�H� ��h��i7Rm� ����`��:䎀������G(68 y��.��@г��F�G�6Xy�GLA]�q��!lq��֑ʷ�F�Z�1#4@�.H�́�ʐ�p�|��X����/���')�/Ld�6�"d�ǧX���j�!�A�6�S��]	�O.6{8oZ53�����6}��? #���K	�4V]<�Tr]��c�������
��4>?L��������x���O�4L�B����T߄��i������E���?~�`卬5�*�A�O)����H�l��Y䦀��fm��[���J�BW�c��E��3�4 _�1�|�����<�tR�a��S����3�A9݁��*]��Rn��=�ڡ�UCr������:8v "�*;vg���j�1�6C��ضH��:���DPv��c�F��H�c��5�ѱ� dK��c�F��HG���I�Z�� ػ��cw��~�αn�wl��#U��gڪ!:�~��{�Nj�s�À�Q���!�s�)>ܱ� ֑!p�1>�q���qt����������o����<��b0��!p�lvp�tX+=	���Aܦ�������t�c������&�'F�a�`m�9���E������ں}�2�2Xg��AԲ�
�� ݎ�e��Ar�(�e ���"�M�wR��$ �9�˖�>�ƁA0�Pу���ȃq����BW�1n����� ��/2ō0�q���#H�yL�	�i����Q���F(o��� ���Ya���"�P�;ę��1G���ލ�yj ���EO����۲����$����"�v7OY�z�NA�v8x���p-O[�}^,�b�</\�S$���:�z���@�p��L�O�2*<��P-\��M����C��U���oa����i�-��?����0=O��}xJ��e�����S_(���xj�[�������)<����&���P
��Ax*�t�PG��!���~�<}�H��~��!M�ӊP=OS��4<��0-T�S`������Bu<�\5T�Ӌ��P��� d��<u�t	!C��	Cd��@>���j��UJ����L��B4�N �Z7OQ!z�އ����B�-O���	)OI����7���x���@��� �Ty:(xڊ����i-���<-��j�#OBWin'<�=P�ɟxro���y��w��J������b�t#����u<|!X��7��VxZ 1X�i��iBN��If�<���S��U�ۀ`�S���<$�6O��z��@����
hy� �ۀb���t<��e���9��Px�`� ���ꜧ`�|> <��0`��S[��p��!t���� ��3�jT����c�S^=O��������,�[��<�v��xZ��u<M<����P�#�+< ��_�i��)Bb�������y*�ZG��(��R6n�
<݆�<H�i6�>xJ��������iyJ�&�ȡ���`h��E@= �D�@M�6H�*�vA� g������~���� ��Oɞ�c?�POq�s;�����C���l3���99, }��Jcq;��0Aď�i�V�<��=��m� ���Bh�Ok7`��o:q�����"������a����b�� �|��N�N���Ӊ���|�3B?��?P��@���s[�@c�����ȶ($���Ӊ�BW�6n
[\��k�Z�&S$ԁ)�M�9���!lԚb&�E��3E_h�a���9Pg�j�*�(���:S<�K�:S��{_�)� N齃� �o�:��Mn�����S,����l�X���:�bB�*����������8H��ۗ������o��p�P���O���O�Z�SP��Gׂ��c�V��G�B<�i}�|�7�i<B��OC D��y�9\΢�����������!��QyJ#���O%�8�y��}��w�*[�tr��N�U������p%V�<�<g%z|���f�j�L�'�C��-�ˑ@��>i
�9"AO:序Y�K~&�/��R�S���6D8���
'U 8�}�������̀<����`��#�@W�g��{Opz��=��#�sj�������j��~�������l�{�k����"��&j���+������޺f �7��޺f��,��|���������_
��a�8��e��yFo�f !t�z�v`oa����|��L�LѰ��9�ڠ7���bo���Eث^E� �?s�����tÒ� /���!_�R�_ `s/��il5��6JI�~R$ WJ���-�ge���֧��K!���͡@	��|!�쥭����{�m|��ǲCp�}8��&z4���$}��b�m�������k�1���驯-oE�ޞ�	o��D�������X����Z
�:� EH���Oϓ�_yl�}�xnU�)Bډ�2�?�{�'�|Dj��ܥ72"�\�ZOz�C��(���+=9W���[`� 1 KJt�C>��v�ٵДkf�sk�BS~ *_2��m����,i_w�󂥭L�?ӛ˹�ҧL��� ���^ �h8��[��-Zص����y ��Z����{fpt|�6��s��K����O���E�oF�F��~aF�g=��c���P�=��Z��G�z"d���х�EstP�#Y����%��p�/l�)�U���.=R�/:�_\F���R�t�~q '�s��#��hww�/V@��]��@��_x�r,4�tGaLw��|rHw^���(�X=|�][�)�5���&���|�[h���L��y�"����ǟ�g�i�D�F{�o���n���YG���hq�@HyW��l �ͻ�mq��?�]��V��Z�����g�����:zV��}Wq� �����v�[7E���ܳ~F��n�-�a���VD��	A;��-�2ѷ8S2��R�:v���1�4-NO@�ɞ���������]�ӥ���y��}�S�+���Sz���� �kZ����+�/N�;��V�8��Xa���/ [�_\� ����_T��/Z"����_TE@}G�(�J!e�c?����7��UQ�����8���/� 仮E��"���E����bB�vU��n���U�- ��U�����t���U��/t��E���~Q��ҕ.hc�(~q�/]4~1��bjE���.~aF��]�s ����h`S��/ށ~�.�_����jo���/�P���_�ޙB���&��Ύ~q!i�jB;�[����_$"dM�"�b�fvV�b�����]�|�Y�2�_4F@�����Ng�/J@���_�ⲽ_������~��B�P'J�T'�/�8�I���/���_��d���/b��	#���wҎP ��q���l�b�v�R�-:)���Yy���r��"�#��Q�bi�*B�tT�}����;�> � /-� �Q��j����G�Q|�M
�<�]�g�M�;��+<O*�蘆�J\G̬AhݑϬ�$o��:*�*�;ioޡ�r{�I�;P���;b�u��w�����`;Ys��y��Z�1�#i���hk�B`+�q���빰�m-���($�h�&���G�z=Z�N�w�j���$W�V���*q5q��j+���K�������'dtp��@����} ����A�J _@��J0rR�R~9�UJ�X�X�t5�j�Ab�T��R/C���4��CE��nH;��}��H�I�^�P����"���|Y�u{�jim���=y���ZCv���!Y��C������+��F�i9:1�C���Mzk���Bxp{�@�;������y\ �n/�S =o���N6��O�9�yd�|f$���;��l���62����oL�v"ޡv
���oGO���B�>��/j�@�8Ę���0�������+.镡_��B�=?ҟ�E��*���#�:��u �0ζu$�K��j�����
�q �ʤO�<��间�ǵ֐>�	R���V!��Nm5��陥����u �y�Q�-H���6Zү�lS\ҷ@��6
��o9���6
�=߲#=���8��AmIo���mҫh�F!����L��5ɮmHגnl�!�5��R
�]n������ҍ�Q�@���v����!ƚ���'CX�Z��պ�u�' ]���͠߾�R���3�E�O�> R�ܠV��������x���?k�08�� K+�A��9�JIr���4C7���^#�SU5���Q�e����Q+�{�5�û��JYh�H� u�P����� �Th�Vr�Rr�Vʠ/�ÇX4�'{G{��$�ޒ4�j������.B�ْSӞu7X~8 xp+e���$-��~bɁ�o��������ň��.?�aMD*3Z���P�S[b1ݕ/��wI�Sߖv�4��?! �i�/IKm=.�RK٥����7M�js���JH�X��B~u�]��G6�	��|�m�o+��)�f��|��������ǂ�4%�ݐV l����(�S��myJ`T��4�myJ`��S�g:f���'5GX��y��?� ��OO��+�B�SV�%ŋM(��%�}���O/��+��'��K�������%mQ�3�=ޛ?^��R$(����|�Q>}��Ci�dŇ�X�<��H_�M��dWi#}��ϱ�,��
~j+���K佥L��������'l��=/�<���m@�4�>��������@�h�4
�G욄#�)4���X��r�)�U�B��`��)��T��FJ͜'Ճ��D��zA�}K����iA0�ՋP6�����j������Ry!�g�\���Oz�u�d������x �i�t���q)ر[����ڱ3!��[�8�8H{[��al�c�ED�F������b÷d��� �-[�f�
ķZ���f�5#לь�����6G_��=Ϛk;�K�n5w�t;D_AqOs����o��5wtʏ�\)�p s�������o��\��#�����t*�_N([�������e�_�9�9o��h�m{��q�S�cYe����ef�F�'#ƙfJw6�jr��2�Ѩc�65�N��PM�JS�@~��e���fE����Lm�R�⇢e���"�jɏGÜQ_m�=�b���)��T(��������M[ƃIiZD˸Aۚ�-�bA>%�2�Q�!¦ɏG�v}��ኹһP�@VDnD>/�-c-�4U��8a	Th�q��|�#�	�ؚ(Nx��&|�#O��V�0zS����
5`_��D�\��]'�|�)�T��h�3�p��5��+����t�G�- =�5̒v{�C+yP
oě�0'K��L�qL�(�B��B��;#�F4�Y+�&�g�t�1��Ac^��� 2kַVP������ۍL��}���aYa]cm�2؜Ǝ�w!�w��	?��}+�*UW�w�ň�@�����.��woa��X��d��=DH^#��ɚzwA�4��l�~T��w�D�#��F�z7��RI�4�si�]�:�ޅ"ld#5�r�널�J>5��6��+���<D�wǽ�ӟ)�������Ի�>���"o6�ֻ�y��t��[�h��;��y��A�Ň��z��y���( ��zg��!k��J���6��wM��mh_＀�6��wo����4�]ÊS�:��Y�Ci?��j�	����5�'+!9"��Ǽaк1ouwc=������Pq�TU<,X��1"7�	R�޸���ؠ�f!3�����Qm_�w�����>�˫���v�G���_��21��W�����.GA���j۸���\_�Jw�!��]V@P��jwiP���a=��z�j��f��Q(������k�j�%�v�s�.��^�e4���S��pq�.;!�w=m�u�YDwY���i�mF��2�.��u�.o!�׺���q�\��4��\�+w�!o���.��k_mc�έk_m#���k_m{�k_m�ڹn1�˘�v�e����e�ښ�ҽ���,��t��}������A�WG�.��SG�]�Q����.��C����ޅA_G[��W����<bԨ�Ի�Ջ�w9�I�emm��_�׻��S۱������EԻ���Z�(�c����鵵��e�"�]w(����w���z�a�j;ֻ��Z��z�ܗ�����.KA�����j���jEԻϡ����ލ�fW�Ce��C���}�] B��*��5��r����WS����k_�^�"���}���Z���*�;����a�gk���������nKM�[]CS���Ի�5��]4��������zW@�Z�z���ݭ?Q���r�w�5)�k-Ի{���ֻK�n�,~�[��j*�n�w�.Zskj�]o^��6��c�댐�jQ�� �EM��y*�c�˯Aa���zw�J��o��ֻ�Ux�ۋ��5���l�QD����E5�z� ���/��kh�]�*EԻ�P|����eW��w���p�w��P��>���'�d�(����>r��9�GS����c_��~�c_�&��c_���w݀�����jW�:T��w��i�O5M�󨦩w��������SNNWW��7 NT�Ի �w��P�>�nW�����Cq��~����Q�B�\][�Zݱ�y,���:(.v��C�aueb��K�kPv�^V#��JM��{w�c�;���jET����Z�>S�	�}��6�w�=�lA�L.R�ݥ��Q~u.�і���I�Rǣ�M+��+q<�	J��Q_�89Ӥ�Pj%��*�F5e�ˆm�|lA�I3��ͮ�P�����,�c��sU�}�*���]'�ݪ��tf�yd�YO����T�O��p/ |
�]U��º�v�`s�:���=���'��4D����U��X�"�`�G��akB�IU���W`�!I%�W�*O&{��{���&,$�ܩ���`$�0�^k�X�S&������xs��+�������"q,y}��x=n%���P7]�g�7X�a����!���Y)��O3��VH���ݩw�{��{V���*��Ӝ��@�oU�ڑ�Qݩ�����)ȧ~6 �F�ũ�x��TQL3��*򩟑�'U)��O�3?��*�)��B$H�~�@nQ��T{�ǈ�*�~�V��Oe�*���}��*k&˝Ȝr`�+�vs�"��ʰ�WV�Zs9���Y�n�P�GWV��г���vP�^Y����n7�
��Vv0��JP����b1�!B�*)I��Y%����9��.���掗�@gK%��C=x;K*)�:i< ����`��8��-u�ܯҿ���d໹U�9�b�$wޕ�E�/�B%N�����J���n���/+���9�/vs3+���/��./�P+ n�Rws�ɟ�φ?��r8�1�!�4 �h/m_���^�}!k*��ܝ�O=I����-��UE�ݼ��Br**�� ���� ~�� BR**�++�h-ΞI+������e��4�#��q�c*:�,z*:�Y m-��%[�4��A=]����ױ��G��Hu`�*��"�c�󛿃��N��T�X�"8�!�����nVp��{��M��Q�'��BgA���E������s�J�v'��A�}���cڊ�UA3�V~U����EP��rr��_��#��./��!�.��'�����ꄇ���~��{_y�3IN.�{W6��ay���22d�G0d���J���Gc\	B�����	X��q	�e=�4gMc|͓�3=�6�VF���;��T9�����j�EP[�5d��4W��ꩌ9�Wx�2DĲ{�������+<uD��W PS��)R���Vq5�{��S��~Rj ��A�Nǽ�� 䤇��K�,��x(-�i1�O=d��9�C;C�J#�N� �z�[��F�+�Q��Bބ���l4�!���*��zpJ;Q�B���v���c3ɷ�|0'X��%j�K���C�O�ܹ�)G��+'�]O�S���c~���/�1v�?-7�a^9��6�\��b��E4�v�rr5�����4�_��^������~�XN�����+������� �/�x�j K�j>�ȉ�;A�ea�	���M7rTY^z��"�E]�v��^V��D����E���߇*��k+��^�S�rea�l�ݵF��}�"�P����������
��J�(�LN�C'�]�������Xw^=��pȣ!�Z��B<��ƿ �
s��`m�e�An �ο �4 ��b,�-�t��H^L�2�`�_F�{�2�n{�n��v,��������]aS-�Ӂ-,S$��u?���ae4N~�����5 7.��������J�TF��Tm�~\Z�n��<���Ҋ� �VZ�C_�ܸ��F��4L�§�eM�_���#BWi n��f�qpi����
�܅�.-[�p��
��Ni���֎i^�"̙g��=;4����[���֖�_9{v<���E�t��!q����gx�9׎g#L�λQh���N�MT��Ξ�S]Yi�`zlOc�9#+gǳ�{��db���?'��K�Ka;i��-E3;s	���gCb=
�������b�#�#X��G���©�Sm�킥Y�ێ?�ɔ:L�O��o�ա�/˟���,�G��D��x��\��FzVu�L�-6�Ol�>�M��z�1E�{��N�+l&����������2h݃7�99t�	�kN�̞���0iP��e��I� �晞ׯc÷�$)i��]XX�K���d�.��F�C���0��=����.tEJ��T-!t1�NUr���驾���qz�K4�[�����]��-#��ZDBJD��y�wB��1�{z�o�*LlC��T�>��5��J��m�������=!%�%�����y�W�%��Iaމ3��=�2�lR�=�C�{��y�Wb�{ضa�s\���Δ4�R٘k��0�
�R1,?9��S�^�.:�����V�C�&�¶R8E1z&����Yr1���?)���E6��K0��a�-d$����$�A�&����Ԥ$L�*��q3Ϯ�P8��ǡr���=R�.]���s���D����߳��?kʞ']d�D�tݣCX��r��_��4З�ͬZX�uc7�+��k��9+��ޮ�\[�$v3������uhb7�H�5VF�K���fw��1U*��$V%�3ưP���L��<�=�3`���1��i.�Ⰱ���{v-W�d������F��{=6�ּ��c��{=:�Ҽ�1���^�b�Dmdn)���-"�����nT��%ā��� ��X��0�Ϳo`�`����u*�0����>��0�%��-a.�Z�r��H���#2"��]�¤>���,�xSۄ�F5ZS��B4��������^��mz�.�SW�s\y�`I
�DY4�CJ��#��Ѥ;nN���2ä����5���F�d�K��$�LR@�h'w8º��~F؍����2���@�9�f�d��={0��Fņx[��j	<�$����0��H(�S]fo��wB��'�L���B)M`)1'����w�S	���-��0w�0��=��U�n��k���^��w�-���Z��)LeT��*���_F�ҏ���JGY%�T���h�L�o���^]7����N�ɂ� ���0g�͐��cى7���h�6�ԮB͓����$���{_�5z$��{.1;�8�\�t��\g�9lfd��Ff@V�3sL��P2!M/�f�"���I���b�*z���,���s���DQ��I�!�\R���	zΊ��노��H����n;C�0���d�X��������Q�-`򈜚lt��	}����"��Ċ>߶	�l�k�,	k����th0L�`İ�J���Z��DZ�3J��006&��0U`�g��'��x� Gra����o>y�k#ӳ���"�W�L���P1���f��Op7�Xh�{��<Ǜ���(��CfPN"�P����:�j�9��(����y]t���:�h�65eOd�|����Z�D0��r=��`m�rjf��U�cX���q�|A'5���͕������=�ϻvdd,3�fC'*��w�/a�qOcX'�L��>�Z�Ǭ��F��`�wN�g����s���5��};��tZh�#��ä��Y�R]����0i5�	�ϋ�ّ-�각�l�Oؕb�I���0��<�O�Fk�%Ξ��6�T�v��[B_?�`0d�e�p����p:�����n�3̒�d��LՐia2��'�V�dM������/�f���9=�]���qg=K �Ȇ�,o�nQ�;�{,��ƴFN�F6V����(���-�Pi�I�ħTxQ�ړn�L�aT�� �LKƓLo�e�'�m:˔9�[����O+̾Ŝ�Zi	��#�2���ȢǸ�'f��Y�ΣF��"��)$-�-���,""�e؍rEf��JVSzfH^F
�x���C���Q��C��޻)9��k��ѥ�V 1^|�����U$ķ(�W"�lZ2��Z�N'���H�rd/�"=3 ���T)3 �g�Z-�3V��߱����o�b\Q��B���������g�"��ξHo>�)��t�3M�|����Ly��d[�X�,YX��Z.d�ydIJ�K̨w��EK��a�[+Mf�4Gz��`�+`��n���A~�=a�(82�|�-�1�F�)E�eH̺�%��sO���{�VЋ┌ڬx���T�tgq���$͚r�Uf-�e��ֲ��t&��'�J���.9��J�d���m�uר�L��&~F/`�»[Ԓ]�$"�'�#sS�kԾ]j����%nF�4�)����_�IӢK����eS�����z���"�_cf���f���Q-�C��N���hѦ�f��%���cyƢ�ha"	�l��!Fr�TJ����def0
�НDA�8��,��۲��Q9+��P��L����E@�#�T"#�r?��M�*K��l���q&��t��3�1k�yt�M׀<*�Q0��r�=��u��mQKI囜S���d�"g�h��X6��!(�s@.�ɢbZȭ��m�b��M[��;��U-mu&�a�6�c�TK���!�C��M�Y�C� ���h��9�7�JaF�����QL��:�}$Z���]R���ۅ�?ΐ�����r�0�TT�y����N���æ�T�)0Ά��Pk
���sV��0�z�Z˥k���Q��Hͼ�i�l��Nt�%񬜁�̩'��5^��?��,�EmF�,����<����&��+����������Di��i�2��6�/�Z��.0?�����y�Ϫ�5%""򴦣�D`� ���G+cF�iF|
��W��G�*��d�|,�[1�X���S�5�Nis�S�[+Y��8ot���2Ȭ��m7�1����t? ?q���+7i�VRcG�p�WBv�$Rsi�W@�����5���(J��4lȧ۫Ki�p;�@^Ƕ/m��R��간	,E�2�2R�-L�rPFu0p��h�aTwd#��03��1�z�D���Ĝ$CjyƘ�c��.�F)�y9u�����0��=0�b�/
ĺ	V�3���Q��c�
�?v�����QR��I'����o�eތ���)n�L�)����ɰ�M`�a�i/��J����[��h����������� D`����$��e�I+�)iy"�n�� :Z0L�b��!MFV��	�<n�S�pkf��ǝ4�0U�*k�Jle�D�g�%'<�qƓ������[n/���L%g�<:�D�4d�"n*�_te�t"7gs
�i1UT5�H�S���ٓ��DS��i��e��˲d����L}6iӐ(��TјN�eQ�~��<�1��HIfM�&SYك�+�h�:'Ǝ�h�j;�����޽c����E O�<�c�+�<1ra��5��"�6��~�
=Vb���	�Wˇ���jA&�E�5�'��6�d��Ѯ��,��j����3&i�@�J6��!5D�K`oVKh�T7^������Y�F�5Ii�mJEc��V�u�c��.3�΋�*�b:�ڥq�C4H� �w�iE�hL��l��wL˴x|��6��F��451�x'��p_2Zkx'�2����	N�#h0���#�6Ir��!1������9�J4�P��n��ٳP�~!4y�f�X����F3%��FE��Z�)�!ɝ�Hk�`i�@2(E�Vd��Ϝa&̑�֍e��wD;�mrh 2��ϗ��f&b��h:?O{���vA��c��*�O���	7D4?N��z$�W;�l�h5���eґw�J��h%��y�p���3s:>6P[i�S������t�)��Ӷ��%�����=�5M��F�ܥD�9��R��Ѐ�Y]�	N5g��4��z,��`�ޒ�(�z(z
��P4Z�|E*��h�~��&��B��̝��=RO�Y�����%�1vk�B��{�Y+E�怶��e�i����0�%�|�=�	c>/ �a�A��h���D��%��P���(��p�ۏ� �g8��B�j�����i�vԉ�6�r|��9n�L��
;����s̼A��EK��f��ıMñMd=���1���a[I��1�6�e�ش\Vf<�&G.&G��Ynғ8�-^��#��48r��-4t�N(�#�,e���9�ϻ���<����5����x�p����z�0J�����Ts����]�c����8;�Wn4m*E9c�&6M1&���>M�(Uvr"-bğqOH�6�J��k����[���H����i�.뇽,4�3���?.�_9��ֲ�}l��1���������/-��VՓBːj	kYo&��$*٪֔��)?/�\�PK��,�y�f� �(���i�O1�G�`�%'�UV���Mٙ�W�(�j'Җ��J;=�!B�)�K+J#{�a��`:������[ʞ�+)ϣ�7kS�w}]�>?�HfJ�E6j��=���ގ=c	=��B]Gֿ?m`�J��p\���J[���)��e>M��im-���fz_Pc���,��?�'�Q�/P��q4�sQ�2�5���H
�cJAI�Ɏ��ؔ�I9�|�I��&�߈%$mRJ����ܯQb�D���>��tޓzbOZ�B�;7c3���z{�Eub��1'|��H#V\�l�գ1F�d)�ɱw�%�?K0���J	�lԗ t�(sn��Q�_���\���%<i�j�T��rkS:T���J�$�k%W���V���J�f՜�%��[S����$ʦ㏞�%@-�Jne�q�{�X��6Qέ�1�Q���:������۷4�-[Tn�7��jٍ�moO��:X�UbEB��u�Kb""b()aA,��i��yX����Z4�T]��YR��9��"i�u^��|!��<J/$� Y�Y��h��bzw/�w���NXD�1��g,yĴ�0L�P�n��c1�3�.����~r�2�h��田֧�ҌGx��JX]؇�a"[7�ۋw�3�����Ym��9�_��X�0�eL[(SnȔ2����̬�e�Lݎ7�/�(}>Wt�r�������6�Mˬ��ߓ��Q8-*M�K����t�Kͬ1w����ӌ�ZP��]c8H���53r`Y<L�X�`����$o#�����h�ZB��p'���,���"=zC�TBk��̿��P�P�/��3#�����_��Y���b��H�Ŧ�6�'��ž'f,�s?y�f�e�Xޘ����JS>j����ܣse͇������N��j�9�8���79�(	yBʓ�<�#X�o�Ѵ�Wk*��^F�Ğ-��P1�x~&6J��ͺDT�3e�5Z�*e�`��'ki3��v6��LǊ�ڤ%�B�;������D�_L�h�D��J��a����k��XY�!��WkFm("�������C^2$���F��rȇ?�E�y���R���QWiw$@�u���O�t
>T�b�Tֆ�k�iYk�� ����Pj�o��T���1<'�*�zJ�PE��ތ��T䑅�Uo���~�5��wc��,�H�Ṥԓ���ŉ�^�L-��I����0b[z5�&OŖ?���*]�x������������V娌)|�3/���s�|�!��"��� �3z���,��o�J�A�N��&�6�ۓج���Lҵ`"��)��j@�Q�=��j]V_;9f5�_�z��>����vy͢��q����c�JeM"���9��iN$d��-AR�?w��D�W�%��r[���̥kt�Xj�ZS��ю��j�V1��!%fP��S.�"�3�4TS,�`^-DLy��/Q�c�J-���a=�Z�՘Z�i������6��&�RdI[d�+�"R�����c�4V�*r��(�{Q��{�9ΘY���-�(W[ B�e�$�o2��f���G�r2��8s)�#j�rf@����U��j+Vӫ�zMCPj�l4d�n�u5c�hϐ�\kK�b ��j"r*��J�T�>I]�0q��ܷ��<��ͭN�ը��f�d�0#sa�y�9�^*�������v
��B���T�[u1s�;y��,��b��������A�v��ē����D�G�7�}A���"�
-����nCVm8y�Zؓ\K14���{2b�1|S���$��,����cQ�66M4��76�������|~����!#�U�F#�ñV�?��%�P#��!��,�T
��'��!���/b��df	�)Z�R!v��lO�4f���VR��|���bۓ¦��U=����]�؎,X]�9]ՀW/��+���>V�ќ�B����Uϴ�a5%?�N���*Y@n����K�]{C�Y�yyO��]�*V1sYt���*vMY���ϸ2�@k��j�Q���!�И�;��,��8#�ʹ�C�j�w�XZ���L����B�',!�Tbi��dz��X�n�EF�#�4�����V�5%�3��Ϭ���s��?�Mڳ_+�k���s>��*��D�N鵖�y�[#�6�����H�朑E}�7�D��wR>���!�,,dZ#%jIji۠��)Eu2|���*e#&똼�+=<$˚����k�5��FP�%����UZ(�A���4K@�K�Z�/&
�rC�*����m�|$����K��b��:{"k2�"�R�mx�v��=u�-[���U��%>�?E5��LhY�'��SjjKx�4_T�;Q�9���4:˳:�re�O
�K�1eqB�o�ӄİ�.(��j:���Ek�G>V�P��Z�O�_|,!Þ��3?>�o�d�Y]X�<���b>O��~����Wg���	�V��4ln�Ț56	fȺ�v�z��E���-�M�N ����Y^�c���?����#�o�D9-����!]�i0lwb��X�BL�C3C�m0��hD��n��8�Ja�K��Py�'$YL5�s��!r�a��3���u1=3�v�<���c�r+��	jq���������t�U�!�<O;�� ��1�e5�+�-�BQK�,u�@Ok@`�W%��Q���lvS����O�3��x��N�A���	�=�L��������S�cX��^����w��ei�n��WK>�gM�U�w~���|��ȴ�(�R�D����W�7���&8�%�V�,�O�1����f�4Z��`�P���Yzb"����u�d�}��ڐƳ�N����x����'�}œIx���H����ዝ�<�aӛ�$�s�>j����A�.�	�R9�9ʓYY:1�n�F�z_��n�?��Dh=~{yx|��Z���=�u��}����Q�kA�1Ǎ�}���UfDҁ��V/�T��]o��ki1 �!�v.g�ؓ3Z��cc㱊�V��J���Na!嘾�A/���Q�n�.NY�1f¥o�K�h9�<����n�u��6'q@��:oƬ;�j5ѣB.[f��!�wtތ�ղQ�7O��%�ƛf�aWՕ�kc�]�=,0������k���l��gX��{�m�C������J����������������~�}f(V������χ�A6�����M��yt�Cvq� �C�ɩ��u;��sSt��8��ˈ�R�:�(���d�n<?W�g�ܠ����2Xy�e�N���y�T���O���|>1}���v���>'g��R��d�_�f�P3�L|�idn���G9�6����|�#��5ݴUBm>Z ���ҩ��w^�:s�l�#�,Ӭl��`ZH��]�_	����dt���u"�LXiƗ�!I��J��(843rI�F�����g����?���XMg�f	���2Sǿ)9�wf���Ж����>%���$�kIf-Zu;���E�]J~�D+x�I����FY��'�Q�:���-�3�D�p�>�X�!uk,K= �]4��A�<#>�������k������C#n�7i|1'�c���`��xotrW7
IEd<��3�!��?��'>�P[�T��)N���NF����ѡ��Q+��7N[Y-UBn���Y�ڊ�}��:����1�t��<-��)��D�E���tն��)���fS�V��DI�O�M�!�m�K�n�w� W(�� wjOK��N�T�'z�4gy�} /:����.��؜]>��=��2V��D?`���V
�Ǔxp�xw���+c�����9Mqr�F�}��ȲF.2�c!K˅�p�
����B-��yg����t����2�I��梬'���`>Z��B����
�{iQv�_��k��%���Da�^B���̜Jj�+�poF+�s�2�/\��"
�W�"w���p��4�Nx1�\f�z!�5�)��q��d7w�������8�Ue���jQ}�Z���\�l���F89�	/LUY���):�ib���Y�>�͒�Ü�8OGM�;��A;Fb:F�P�v�P������_�y=��e×���uЫD6��ݙoO��,j��&w/XM��~΢tr[���qX�@'��)��Z�`�)Q��M�륤�/N;�z%u/\�!5=u��r�����43�'�#�"��"_p�"1bH
-ɩ�tͱ
F#�4��}6e�r�s�ХE`��ƨ�����P��ٌLy�����A��j��FM��o:���r)�osؔ�cq9��+�ͬH�%���IFw�l�Y� �dYj�N����{N6c���nX���fgs�F�g<阇}r�+${��b�	'ץ���z^N>���uī^d fE�8Y|y�h&���4�2��3͎�B�Lp�3֯�5��L[�A�D�Eb�-��dU�4�X����zq�c�"O�f�Ⱥ�X<��k{k����O�0���7õ=^���J��qب��+���su�%K��V
��k�D�����v����ϱ�w�)���`'_�Mɷ���ڥd���$R*���iR*5��cJ�v)��JS�^B�t�V�EJ�x�~pL)y�}��~�S:6)�L�V������m�P�i���?���%��[	1�dަ(�(O%�.������ˣ�ƅ�v�x�Z'�}�ۧ@�|L���c�)W8��G��ڌ	)q���9�:ӈ
k�۩I^2T;���Չ+��zv�����ͩ�ߟ�K­��%���f9�V73�6�j|�]�r�g�hȚaz�N�˅b2gt��7>��ivO��g��P�G�kx=-�:����Y���Y��i���M�8�?B]�G���FGI�'h���G�G�9<*ח���WZTgO�X����-:/#�0��?���;|F�f���3��9XDR�B��'���s���E�iܽ��֞���۝������2$���ol��Qԩk�r���ƌԜK��cD�Ctc\e$t�2�Wmn�PlW���FqZ+CVf�?_ΈTOz�>8�yTV��;.^<�4����=�ɡ��̐|s��I��ٮ���dc��B��(����hzfi�ѭ�6}��sv�Ͱ�Ǯ拭R���e���ⅱ�J��?�����.�^�)3��n���lm�%c(o+�о	������X�5�׏PFʲ��ʵ�E�[j����5\��v�֔�H9��T�k�S����`���1o~�3���wVW��h�<��yX~P���	�B��T�V���p}N<����L9�+��K�?&��]��>"���.�:������)�Ϝ��6����K�����������a�\�h~J���Ns����Y�cK��YT�����Z��{�F˴.P�"���Ml�<X�u��+3?E� U�u�7Dx��D��Mi�(��<P>���xW���Xb��%fvq��F����(�
.]��P&C$���ϔ���b�c|y`��l�z���E�c�E����t��L����H�F8�Y�M��2Q��t����{-ܠ��//?Jb	��b!����+0e�|řM��S�$��<��l����|�A�����Ub�Fz}2!�	��!�Ue�Կ�zR���3Y�4�k~�J��>��&���$ޫ���Lt�6�(64�����r�ܖ�o�DgϜ�B�2�Q�ci�qZG6�G�����)���%4�:��<����H�O�O(-!+��Z֢ɯ�M,��r�䵌Δ`��RSj�gZ"x
�7s6洉~�K~�J0�̹�n�ղV���zR�3�ϋ6;�f��L�=DzUpSL���8�+��%B����S%֥d������7�i�i)�+R:�o������6�F'6���DԱ#�;�1��=[���I���#�K86�΅����n���;�o�����(�'��ʚO�y��Y9�ijy�b�?]]d���n�DO�{!�&?+�^�s�fG��t}ШJ��l�9����+F?h��Kg���=vv�\��Y��W�^����@Zc#߶����,K?���:�_X�SWO��r�7j�{�M��G?Կ��S���!�&���bYmL^vL���Ō;l���5d���z��4���Hw�;�ܩ�:��&�2b���s�ɏh	�����P����d`(����x�lRN	nk�L�f�r�/&�S��)�u1����2��w�+�:%�����I�:�3
{��K�7��r�Z+���>G�t�-[�.ܗ{C}����c��������L�4��af�;6�ʹ��m�o�x�Q}p8��O��ә���X�
��4�4RC�"K���cK�E��ux�E���c���b$�O�o�g<	杼/�>��`ɐZݱ��Uw+J�"���s�F�+ʚ!�|�E�.ơ,!k��r��ª��q�|9�k��k�_r�nS�|��"J+�r��#�]�ȃ�D�����iqG�x��c�赵�����iC�$�F��7��|���6-oy��Jdf7�g�8��0AT������p�#��ߌV'Ea�fO!/I߿Y3R>t�٭Kkd��椤./%�]�"�Sɴg��	tL'OM�d�.��KF�N�H��8R9�0�q,f������x�}R�|��W=�3Ji>^�v��[�)��Ys�7MQ��
�c��&��%�Y+�-:�?_�`����V3�;�/����O��&�QT/>�@��k�<��s��;�u���N�'ب{��^�����G��F�$��d������,T ��J{-�F�0-6�䊚�h8�w�zy��] ֶ��7вK�['���W)�-����ǖK�lT2��z�1XEIc��T6���'�z�S�y�y+.�������k ߁�c��i��E��,���F�N��	m�҇����Ɵ^r�iV,{��Շ3�X���+8�s�'�x�m�N8\6�f�*A=�/��Y�,�GM�T%��b�D�Yc�#ᶯ�y����Q*6Si�&�x:�>:@����ܴ�A2���㇊�A�4�ձ�W��9F���k_}R\�^��t�=�`�8���Z�Ja���"QGƍ�նӟ��/� ��5B���*񊈤�%��cO�.w��5/�@�s*�>�}�e.-�Q��R_��9-�D�+��o �ԯ��>Η^
I�K`�����
����0K��e✖[��YM�ր%bE�"������7�	�8F�	|�,�6�)�Y9^�;$xΗcYR�}h���7�}�yݩ����Qh�|q�$7�hN@z8X����4�e�S�`��	����o�u�>Ղ3�ˉJ��d4W����JTV�S�R�Kf�<�mRiN�BjFng��Q�f�JI%�`m���d�V�T��`3:~d��P�� �|�g�R�B�lfٳ<�w��YM+�d?r3�K˶�#��7��=��8`uu��!��<�ǌ̓Ǡ�a������#C��l�.��K� 0&u���̣�)�a��+��to,g��ZN�}u��:md#u␥h��[b��������Sʊ�����|����m��'�ӓ&>���SQ"d�+��B��5����H��f�� j����qhւ�B�X9e��ְ���1���z9ѪH�F�3�]�e<�/LfFZi.�O��TArF��no�	h�s������R�銮���x7����̐��F��Kp3%b�+y����n̏+�l���sߦ#k&q�l"�}�Ύ,��-���#���Ә�8�3�oQ�8���ǁ-�N��k�|��΁���H4L��G��b�R~�:�r�����~�[�Y(�h�̀��b@E���ʛ�6�� o�Xk,Aw�CY'D��%�'��DڸzLZߢS�y�X��c�1��c�Z(?�-���1�Ћ5�F��kv)=�7��M�z���>L#�s3+Ĭ{�.1P�W�ج��z=�c�o�#�;HS+��@XE5�NM���Ū$Yʂ����)�X_��BgĻͼ�+_�;��8^Ge�s�r��v���H�>�<��^iy	}Zu����3b�-�(��I9�_>�>+�[:[o��Tch^{�dF�/�D���i�S�C~0�r'>�C��!8��@�����{b]���,�b�U�$�)�&o:�/y������|N|�u����p����ft�c��yl,���"3k`K* ���#�&oe�w�Ŭ�(��rk�Kn^G�ͣ���tQY�a��jJF+�A�S�'�o�bo,K�tLi�4i�)-Y,��!`���c�p��x�&½�>+֐��7fc�1++42z��BD2j�X��� Z+k�ufzyI��z��Hc���w������� 6b���������'+�|�z�[M��������_M��Y�>z,Nb�Y��R���OPܐd1X���d�ywIr#'��ic��*���o{���b��:K��1�3�(Nv5jv�_��c����-�u%�44�h1}c���﬛�c}{�B3ݢ�Ȉ5�����T�4���,�%�ke�n��	_����q
'jXV/�Ͷ<�b<��xܮ;��h���)R�ez���0m�C�<;���z������+�sI��"?Ώ2����J�kF���r�a���8��-rLߐ��V�1�jT�1�xu��&�x������h+��N��������Ʌ�XS��l-K�e��].�-
�w����"^l/^#��q�t['�k�"ݸ�T\�O	����Y�<c9�x�.&k�m?��v�q�5��H��R[��H�!m�?�������Y?�,4�o������!��L�H��t�Z�n�?2��k'yy ��K/���we��� ��&��W��6_J�v����ѽ;iO�7�<��u�1� �����6#�C��y�P�)>�P�@qR<=�����)�H�Ϣ$��x��Y�'�Btԝ���MV����EHӴ��h�WL����d�z��lUY�X�8f��= �>��7G�6`��q�I�����6�$���]��R4�K�|��F��zĮ<fi���}��r�IG+ԏ$�/�-��O8.z��7�tSl��n0���S}����Q�<Iv���T��[����H�����UG�8~��j�`��!e���;T�?-3o�#2������,,�$��7�j�e�z4]�KG���t�;<�w������{ibHX6͌N�_�Y>��!º�#h�"�ő����D�6�i�(�-f9�A�^�3E��x,�-�H����]2��-��ll}��O4=|�5iHa-�=�k�1F�_zN	L�Ӕ1X�b�_��Y���`������q�Ekz����'�f9�~�����ǂ4��<&�g��Ҭ�˪3����N6�56.��Mf�]��&�VU���
�i	���w1͞R���L�%{��^�����0zC#���1��P����}�g�<�Z�h�7C��蝒�d��b>E���N�S�V�q�EkD�Ha�)�0h�X���J�L�z�S/��Ӝ�
���)�q{:����l�Ccb$�>GM�f��¸2��6�D��1�~�k~!�
��2�5%���hS�h�`i|[>�)?�Ⱦ�x �i� ��|�V��]�G1�n%>�G�\m�B��\sk�,1��S���qI����ie�U��<��o�3��O�*O�i�>�,�u���W������l�}3�=^��l2�1���H���مx�./�w��MI^%��%/��[�1���t�9e���?g�,O�n�/�������b������� v�����}�R!�ͼ����Cc>V�1qj�Q��{�����Q~����a�K���b-B�U�y�˪�N�i�1'J�9���\��޳U���p��X"�a�)���:G �*S�~i%G��N�LsF��xu6�;&��I�q͐��*7�|�5ӒS��+���xZj�J�a���he��&w�`�I,��!* �I&��O�ԴY��]�l�_xSg����<!w:6h.���N�@�����XM�0Ec����ϑ�!L�3�a�����Y<��c!�EE�UY�nǖ�X�UJ�����X�=�8�Ϙ31]��G.ASH�4S���ū��U������>��ۧ��0��m�E�6-��/����ɹ�1�1�$���`k�l��ae�:蒰úN���@�y�Pm��:�}HL]6tХ�g��:�X�s��fhq���}�C��,�K����`�1�b��>J�QH�>���'���2���m��δ.��Q+�h���k�������OtT�~b���B���=��wwћzv��(ox�d��EڪC�J�'B�^#���G��W����Ec��|3@���L�O;-)�gY�v��}����&]xZ�u���QF1l��x <j��Qa�%V;���G������L�����)I���3��m��r,��b1�>�X���w�o��m�JC�,>[��+%�/�H��&fq�������]��s}d:3f �ǀǟ��n,�w�8�+:��h�#jxվ�
Rz�?Ѯ ���8 �ݢ.0��Ώ�f��,RDkq��:k�����Z��[kh7�[��Zt�R�⼕�>`d��s�s�	sL��^�b��I	̶�4~F	�ڷ��y#�IhXf��)1� 3�����l�w>#�?m�(��w��|-���g���lĨ�WY�+FJ�%�����������8B
f��,��0�A�����22�C���)ln�
�PV�~5��jk@��3w�|�#�{<m��Z�FƠ	��'%I'��D���r�cV߽��S)
�6��'�>?Cƾle����$�̈��t���������3>Rp�2��q�2F��&8��x$\u�saJ?�%�3�u��d5K����D4q5��� �t�^�$�Eft�ڙO)�Ґ��1� ���7@�A�]ʅ��A5��*Ժ�Q�r�uc�n����X�
=��	����lN�^`��O�˃�2�x����nq4g�����"��P��/�ߍ�����x=u#�m/Qc�?M�Ą�F��V�N��P ��b&�M��L��ƿq�S�Z8Z/�3��i(fZ�3�3�1,{��U|���Mba=�9vN$����s���̂�|��2�[3%k�����CF�2?{�>�ʉ�A<��^�=���E�����V#x��{���
�J����,C��Q�$�ˡƳUkl���K�q�ɐ܌'��ܠn� 5D�5���OaaƓ�m���o�!:�e�v����/5?ɞ��7�#wco�Y��;��?:C��d�cs��c����$~�X��9�ߙ@3�6)\���D�U��A��CM�r�F�+n��:9"%CÒ��YM�|�}kȍ{�� �U'T*4���\��h&��e�14�X�(�EŚxL���0f&Z��F�o亥�
��aǟo�\��7F�e��9͑��;��5����$��|�}�5N��W�v�q�r�C�1��!�PO9y�@~�C����"H�]�T��Q�X�&�4Ю�);�I�ϊ�8��/���Y�4���UZ��T��e�.xclU}햱f���9�C�Xq���bRgu���v`�8�|a�O�6�/�x��xK��`��X���q`<��bQJ�2Zd�+�6?Q�~��%��r�5�ϱX�����a������hf2�)���S�ox��R ~���l����%'��鵾��7��#�)'e�U�.e;��%����V2�}�m��(ȫO?8&v#{`�4O�����$����r�»3��pUR�T��#Ye��YN��2,�~�nZ56���NWWq��,:I@?nV2jr���u��D������ʗ��+���!馏�rO�t|�&$3��}\m��iy/)?N˻$�=�c�K��'u��	�yG��z�5�_N��9Zm(���w�y��v E��q���[kcL���D���9nf�{c��T9�~r�=�-�}�֡��irz������V"*�ǥ���3�ֶ�6Oy̮�n���vym{n�N��V��s��r;�󧦳�=���31QR9�R8��F�e�q���u�ܛ��~�"|�-j�)=�g|�yNWJ��+��/���~��XS�j�J��h�l�.�:�H�9���}������Q��%����oTT��UIo����6h�os�	�"�iW{x�W��ʿ�0��sza��R9��x8�>0c$�#���"�)���m&��=3#Ⴉ��߯p��=���X�<�FL99��69p��xR�&|y;���ӯhv!яG��ɝ9���uɤ����$��	(`O>e��q��N�μC�>b�ɼmʡ��RR�B$�����^K����H^����Y.�NH����*S��s:�\�n�馜^��{�I�3�]��c��t�6pL�-�)-�һf�U�;���v]��Pf��h���
��7��"&�
���<�h^^*��E>�����1�>L�̯I�b*���1ӳN|(=��l�i�,�s���W
Y�,�������B�^�E }�'�չ��2��k�����Vi4����t	��Ȩ4�)�=�E��^�/�v��C(�O��v��Qm^&ϯ	�(-��g$�Pc�=5�-�WU&���ؼ�)Ebނ�*����Ͱ1C_Fͮ��ɯ�b�ؔ�Φ#	���3�$����?	�+H��'��>���=[?� [C��@_��C���Ո+�1�Js4�{S������J.�s���.^_d��GS!:�P^���t[�D�#�1n�g�r�W����V҈hC��"�5e-tee�t��z�\���Z��S�s��"�|}.��y"��E�1=��݀��������e���l��b1�*�C�	��)�|�kO���,�fk͋¬�Ӕ�Rg�P++��M�jU�L�lTU~|٪|���Q:33�\9$��,j�WƖ����;����7��c��:�pC�K���ZRZ�(�q�N8k��7_����i��������p�����g�9m��Z0U�<cr�f��a��ö�W-��m������,�>̍�p9�l���U���3��M�·��B��#,z��%!)�i���d:͒�7�-� f�ŉ�q��&�ɂ�m�H!��YM��'���g�c}Żv��t�,d_�O��)I�z�/�Xݟ;TY�2N9f0�0����VW�|O�S��ħN�礲�9)k����Ӻ��*٥�̯kT2�\�¿��iI�3��r��U2=j��_F���
3kf�Lm���,)�H�օ>���@�8b���a�)�h	�>@�{>��"�S�=�mȴ��P�;�Q!#���ő��(���bMi���2#k���Y���pՃ��0��_��C�U�\l����~��?-%�Y�T?_Ţ._y�?Zw�U=ǿ�Gj��u�����l%�
}������;�5@6n�g���0�>�љ>�7��}�)E4lm��w��/��̊3o/�Ӵ����|������k#`0K+5=Ŧ��JS�
���Ғ���33Ķ��O+iZ���To��p�l[I�� �z������@2'�h��Z66G܈�p�m�mc� ��K�a���������G���m*-N���v�����0~�'6�:�e��x�߄��:l⇿D+��_�Rvut���|���^�����N�ȵ��A�ʕ543r_X#'�*�9��]>+�.Yq����>�i��<"v
�q���_�$��~a4p��eӵ)�#"��o��m��wI��$�ؾex��n�:H͊���� g�A�;�ÙSP�O�Ĝ�.Ve���X1NbR0��&����<%_*B��X�6�#�Kwzw�>�N�4
r�I����NC��4���ս�@�'�qH�����5�<�ph$*******jz!�@�(����4D��`Èb��~E�]�D���r��sB������{��͓��ٳ;gwvvvfwv��t�jqIYQ�f��qv~:�����i�QĮ��;��+u�먓y�g�Jz#Z���dZ�.%��N5˛���Y�և�iޡygQi�+����E��Ԟř[g<�Y�h7��d�L��\]��S#z�
J����t�K8Q!6�̣S�C�����lB�\
r�vNW�m�hK{�N�$ZN�WZ���V���Zj|ij|	�@e^t}�P2J�Z�0���c�X���F�]�VD�S��b�=ﱁ��t����m�T㴅H�WYJR)#��27����F�L�Wy��Uq݋�VF�ҫ����t���n��$�0�z(�>��G��uU�\zY�m^Jd�L)b���b%�������*
����E���:e�S\?%��J��q	����U,�?KY��W��?��e�C�)M0�Mz��r�~~��NJH	��۠�DZa �R\߲\R.���j�� ^:ʠ��|eSOj�oUOʎ�Q0�OȢ��y�؃<���Ǉ0�3C�C�4_�ghs0�Ny�A�v��c\.�!�ӑp$�6:L�{�k�;:�	�5��8����y�,9��7�f%Z`��G�B,#�Ӓ�Æ�Uo�#��1e�B��YQ]7�è_Y��u��u���s��\T8C�5��(�	�`4�оz�+A��>O���ov���i��=b6�:�Eu.��}Ah6/�̖:{-�G�,N��F��	O5�����w�R9:#4�\Ħ)�n�!����zb3��)�-���4�k���b���t��E��z�@��Q�m��_7�Vx���A��6��1q���zp�L.L���W�O�О;�[~[���:��[��V��Z�cR�:��꠹y}�~l�w`�u���1��hV[e���p�JP�N7�m��ѵj�~��[MQ�3u3�XL`�V)J�B��ZH[V��-T��Z9u��*EuAn�S�ѿ��xv��0+��F��h�5��\�彵�F�^�{��5҄�U���c�~�d��Qʏ��~L�E/i����j��Τ�GJC�_׫�t�.d۴����C���	ܭ`\GY@|9_�r��(��*b5��hѺPC��I֗��uu�r����%�=]���]].��ۋ��QK��7�T�^�+@D��R�����t�d��2d������E��k^�F+?��}dm���ڥwd}z3j,��i�ґ���ُ� �#5tIZp!�
L-0�xeX.��-���e${�J�����\@�;��u�p�S4E�'͏7�\ު�x��3��4?խ� 	#�6����MXb�\�*�Z_)V������+�h�D��M��~uҰ��`�ۍ��Pm����ڢ8�U���%xdͨܦ҈�6�A횈�� y��n�d>�g�`�^���ט��F�.4���#�ҁ��R{L[�"|BkݾJ�e��X��"�O�O�%��e��wм��w�#_�9�(���M��M0ju^����������^�!�ކl�����*��]\� kI�q�kro�t�v5��S�$�����κ�އC�P�Z�2��y%���Y�X�豆�!����;�
\պ�	+��sr}(gt���8c<ed�l%���Fp�"0���Sg���+��8>��\��<�$[���R�ʍ-Ǿx�Y.؋gA��hu�­\����KќҫA�ϸH��Z�³��͐tB���HO��U܁&������uxG��JC:�[jb%��J?u�ȷT!���CX���4��M)�jA9f�@K2@���9yO�R����t��%̢-��>R��F=Ûo���I��%ݴU�����@=�U��7PN䊙* �[��o4u��M��������?5���8��I�M}o�FXDVo�6�ڴ�)AmxI��n�г�Tc��Y���Mtx��ZT��3�t͇X���4<�^`�F�My�@�4"���H���x�d���U���x�+۸q<>��<��Ĩ���R�_f�����Y;n�B3��7��[�з��	ƿ�혝:�-�R���^���l+�<B���:O1P.�EJ�����	�+���z�#��B�>�hd�%4fV����R�/�vG͈�*���t�W�C�rܸJ���Xќ��P��a�'��+L-O`0�]Jŏ'ןa�B��
��KP�]F�V�Q� :�P:=
�p�a(�:�*��0u,�=�l>#�Sw�˃8?�ԖPOo^�$����O�a1&P��<�ThDk��mߋ��T�����AIJ�I|]�7�����v��e���2N�՘T�)/t;;��,�q�W���?I)b�I�0M<�6Ł�SV�q/�q����c�fB1*�+{�Y��Ę�l�RV7ј����	�=�� ���j�h��0@�C��i��O�_R���.�F���r56Fn�	vbO�A?ўv�N�b��}��#]~x	u�[�9��.ػ����*�VyGw���\6	�h��o�N������~�ǭ�7\Co�����m��x��"N�X��Dl[w�/PO2������GO�C�`��=�b����M9gJOs���������k����Xc�ն�o&��s��no�/m��I~l6i9w-���l���Є�}@�9�&]֟���E�����Q�B0���V&�ʾ�͖�'~��rH��c�e�:��B�5{�|�R���r]�`CG
�Lݬ��3݁O6,�9�;��j��Uʽ�2���4�o/���|Dӧ��D�Z��Gjg ��nd�]�H�5}����n���%y�Co58��=�Ǳ�P��ً[�!���C�]�E�:�Xr2B=�9�pzeB_ڿ/�,���{B=$O� '�M����O�NhU�
m�D�5�^|�~���-�B�4��`�Q4�PC�������L���-��x�0�R�Z��;����u�x-�5�&Ad��U���ݠ<�W�b��<w�c�?�� e;�϶�0[Y�l���
"�f���6$l0��`x,TB|@��@nz���nC0�a,�F)�V���sX̬JXLkc�a�8�[;���d!Ȯ�!c_P4��; �%����<r�wԯ[��ū�����j�ՕY$�c`�@�����(�!��=�ƛ#O����,g}й��7��xVy>^�̌�z�7flAS��u5yء�>&�1N۠�I��V�7�ݩ���5`�
�43�]'�QV��U���f�&��iF�����=�aw[��R����H=Ԇxc�/�T��8Y���*C��eki x�g��Y���8�����������uKh&�֎�\��ƃU�¤r�VlCxn9��;c������z{������z� ����"�4M^B3}
;]
��n�d�d��ɋ��_C�� ´vP�4#�clSQ7X(m�y�Xx�X���+w_�񡻰��G�:�:�X�2/B:��Gq�� ��Ğ)�5�Eij�M����G�௤]��m�^؋Wӕt��R��h��b����5�k���>gb�.>&O��]�������1�6Q�M>��fb:YUQ1h��I���:�t�cY^�Y�#��P4���-�mF��d�K�tr�D��z�4�n��?}�I�S�J7�2�ݻ��ki��ܨ�n��JB��A�9Vw;�q�,�Hcz�yo�3z���@�Ӊ�hؠ�/�q�=]I�̭R�+ih���I��rV#%���c�Z�R�,��Ox���P�R��>�2��F��RG5��:�X�Bh]��k����t,�ܐ���{��x
$$o���F��?{��o�J��v��	�ɐ�[?�i�e�Y��O���2A�\H1�V(m\}�n�6=[,B^=��})��Ju-�YMaNŪ��G���d#��ܯ�O8��܄ZX��ЯY����,��|�erI��Sh�͵���BCNǄ�;�K����*��C�ڡ��M=:����c���Q�����!�W"�vz���
d��jVbȕ�UJU�)I,F\��4�M�qea�E�Fz� 1K�ƚ}9��w��t+���c�����ld�`���z�̾�d�5�&��W�Hym��`sC����
�M����Z<;[��Z�<����8�L�h�fTK,2FP����O>�V`�:?���=DFU(-ڄch�3z!��}?�H�׷8���!���X�ȡ��6��%	���1Zs�coEǜ�}�(��W9k��2���;�[?������KB��G4S�?�/X���:��7u�������5h�!�/�2�rS�E�a�C'Q��Zb { E)��?�&NT���f�>δ��x5�d����S�F�I��z�c��`��CW�v�7PM��EWtl$#�	��
Ws	�hx��qN�;jn�h5UIP�лJ�����R��)c�㘧HKlMwx�n3�uj35)^�{�}����>B�N���K�e�h;(!% �E�=k+ۊ�W�Q/Mh
|���ֿޣ���-:�3����Z~M���EtvO�6^�ʹ�U,�t���IM>�07�
=RK-��V�zj1��\���(��S��]vhv�{�����ʷ��r��.U3}**U�s��:sʅ+�*�jJ�h�j�b��F����Ҿ��A�a�T��J��ϲ�g�q.��]���_(��ϱB�׫.{>�����K��c#	��\�\��,���1���:�p1��1�L�&#wP�� VI��~���x1}P��*��1襕����Щ�:Ѵh�ᩜ�3�R";M�5f��i�0b!nhqh!��B)��:�Yh�U�A]�:ޢ�<��M�+h���<1Tc�Iy��^	��,d���A_	�:44�V7ij��F�*�e���j���J|t;�)ځ�,������Ǯu�]�	�Ȓ�ˈ�uˡ4��m2�En����! @�<���ɐ�
C�P�*�r���_�Ĳ�5�K� �Į��O�Ĕ�V�N8��7�O��I5x�_6�v�UB9�H�N��#v0�,��u���1~ L�)��N�sF�� ����p��&� �ЉcZ�*�b��W�P�-�CK���-�ۺ'���xjAR!:U���(/�l��c�lwt��T�v�q0f�'P�r��_���I������N�W�/ҿ�^�j�<P�{%6�Т�gWP8�=J"�0�j�uF�n%�0;x�����4a����ߪ�-���|h­��g�ߏ��nU�n�Y�/�YhF������P`h�� ���U�ր8m�L*ꙑ�ez:9��`+I��/����7�E�&�Z�s��48�	���COFߥh�T��rڥ�	@�v����ނVV)�V,�"�Sbї���-��)A���qC���3:�уĦ�)�uS�L��@Қj���EB(XrGwW�q͆���q�D\��2�8{jvU{GWL�׺�B�
=XV,E��9�~*�l�S�|���:��zbƎ�@ܬ"��ϖo�Ǡ}f��Ǳ�A��!�e�>�5ڇ�1�
l�887�A㴪�8��k6N��J�4�o�8�J}��U�ԁ���VI6���_7�3j$����k䧼����N�[8�em-\���E!!{ٙ��Y�vrW�JW���(_k)4h�2�
{_�����d��d���l���*��x�a+�R��p�?n��V@kU:��H���/�Ȼ�ŰJdwE��H�+Z�Q�=F����Z�ߤOd^�7N�4__UI�Y�� Y�����&��έ���� +x�!����#+���U�`�i���W�G����(�P���@ku�U;��rV=�؜�����CWZU����6C�0H���P��:w]g2F�t"ڳlC�����Oj9���b[*>� �R��>!�
m71�A���wM;�ޭ>�>xZ�8�0��^��~���2���"���?5px����s�����hy������M�>!�9e�L)jn⭩Xǣv�`W[T"$�z�!���kÍ�>���>�Y.�E�q�6�*<��% V�NS�i!���R#S�7��T*$>���GʮB�k���B��P��/g��Rk�s�R#�$�E����7t�q9�69-�Ԣ�B�ʾ�5gk0ͽ#�=�1-Fϣ�ͯ.��fhgp�0`�����'��� >�՜�5r�,��L�=��eT`fa\��UP�[��fx��k��xrL�k�Z�g����X}�F�e;�2�Gk�Ā�PG$VZ��[h�c��DZA��4�J�����sI���TJ\V�s��w�U||u%M��Hi�[)�h;�-�q�T�7���$����p����7�-�$m��a�Z�T�Θ�E���;4;(]�}S]��/3ŕi,qC�N�G����<xmA���9�T� Q
t�  }�`OV)ߌ���>��6�7����Ak����I���R��˅�j�b9�¥n�,ɜ�����$]�Y��iu,I?���>b�O��܀����0����hФڳ��H���y��*�/��S����I�^��Ƭ@l�A����~?E����o׺�������ʨ�Yl���l�[��Laʨ�"o�ț�"BT�P`����X!aў ���{Y��P��`�z^݅��bcm��;ר�"z���\#�)F�IG�������2�w�raI1Tu��i�ֺ�ֆ!�f%�)�<�)FyU|�ZQ���4z}�n�֛�Qt}���a�ޅ:%��$ס6y҇_�P)��Jl�n�G��B%�A9?��\��\��G���\�@��:t�kL_U��:��G�jl�����(5@�n:O+`��=�V�j�W."fDby��u?�:��\��K?�h�dU�[��pJU��¢������?�>.��X7���*]����(%�Z���؀$��C�i#��QY��`�*�5(��?OUPn �#<FV2��D�k�2��D�Y�H�bhD��C<Β?��}���hIoE$�J�m>��n�T��`��&Z�㽪�)�9j���z֥�ϱ�i9��t�ѳ�1��ة�t�W��nJwbh�a���\�@O������j潯z�����\�R�=����r)o�x�趐c�Y�i�]@�@����'Ql�t�2�JX�TH{�6�%�D#��������T��V��u�3�����9ڝ3]o{��V���~S��r��*i�����U�G��$Q�)��CPғ$B�栣b�1�SH������ޯ�<��i5B��34�`�ަ�ơ�P���*�ר|��)��������S��
t�E({�����	-Z�����o(6�
���� ֐f�x~z���t�G��?���)U����X�3�n��� mo�ٽ�#��*fk.h��	8�����cP��ts%�zY^hR�b�	΀�]H������O����U5*��Wè�����-핱�q�����8�5֘�е��A���-BޯԸ�Q#��5h!�X��jR�F�M��'6B���F`9����h�+�h��B|i�%��q�
���1�����8_{�v�;T�� �Ci��E�XK,��i;W���������G�+�g�Vw���|��a��#��8�yJӪ���x@�c$F�9����=��V�м?�Ӌt�ҵ�N�'��hC�����nW��G��3�ۆ�8�Vc֑°n�@�h��f��]��I��Ì��-�6['������nU������7SIl��]y,���P�/�#���qq#�׉���0ѡnqs���;�r����0-�_}���-=	���ݯj�y���4�j]���AtG��-�G.�����咂��o�����݂�n�{M�~�[K�?���*�A[@Z#G@���>V^�;��y����/ȇmt���1ܢ�:Qq�:E�����h��t�<nެ����w���&+l�t� J�����n4��#��ָ��*��t�5Qʎ�v��b������.f��$3q��>�;���<���P��ߤ�"j�[OG]b+G�8�'~s��C���h��*�$���=Z�a!�,d�J�U/�AAS5�Dl���Ko�9���� ����Q2��ԑN�W��g9��-ނ\i���trU��lL��Ͱt}S.��ZB����D=$��i��Օ�V}o_�'�\`��u�f�ة���/����q������?�9F��.�q�6��	a|�uC���5��8�0����0�)ֹK�$�D3$���t�΋Ot���c<�J�2c��x&�B'^���[E+\)���2ӝ=�@Xl��D�5&��m����<BQ����;�#I����=|^��(�uF�C��O8@�hI�"�j�0Ac���V���L�mMO��wԳhVK�F{�:�z|9��+��uԉ�`P�ת�۔@Ғ<�N��+I��hPF�a`l��k���:m շ~([��쫆��:O���5�݉�)��G0Z��T��)�\Z()нQO):WOo�<ޡ)}��4y��]��z�A�|-��'@�qh����!��P�Gf|�?c2�zd��w��]�Z���`X�PSshyEti�|���� l3�oyg4���lE��h���}��%���m�1ڪ�Bjk���m|:=
��m����MLg@!�����@�������si��1_��bx���9����C�2�h��d�{j �`�0�Ov�����]���y{�öi��h�I����h ��8=ve�K��X[���|L���k�[�"�o����"�AzG.J�^Д��D1v�����Cg"��r����/z�
�͎���]F�/�t��c��՗��ThfM߳�{&}Ϡ��Q�%Th�����<�)�@.�@�2닧cqi�R��^u(���h'��V��4��H��j�7[�e�:���֨�c������{���)���\�����%���G �ۻc'E��2����Y���3Иf����5�:_��7�~�A�Dʁv�ͨ��K���K�/'Z��g�L�c�x
&x��{�kIg�v*�y�S�QJSc��f����Z�S�gb��O���@�TW�
*�6�&_^��/��.J7��bN�	H��ُ�*�X�Ki�
��7�%�4j}������3�����:�Q) y�Y�T�W�Q#�M�-<5�Ol��@95�9J7k�M)u�J.����2�J�d�l�L2��Tu*�}�]��M��Rz1!S��n����ɦFq}i����x�qCcc��)��������?Bu��g��Y 0���� �/��������{��4���9��,KM*�ђ�Cd<ӧ"��[;n脫*���zj��3ϊx��x��W�.Z��]�?�����ߨ��� �oλ=�Kbs�M�Q�LH+gh���b]"�Ҟ��o����HyQy_C2��2�k��9�H���|�0բϪ)n����};�Ry�Z+��lE�5�p�}�M�Y��O��N	�b�V'z!R���j���Ƹ@�{���*�*�@����M�*j�rYAM*'�?/��2�L��u�46,*�H(9C�W
�u��gj�	<s��W�S��>ZEW����^��B@*���+Gm���ZSGc�{�{�4x� �,��*��0J
�L�c�g�>P��mh!�T�$�<��;�Nj�;���)J���4��fz�Izh�:�  U���DiAuŶ���9#�Bsx�IVʦ�p�W�^�S�8A�:�)�p&���(U�y�w"��1��v"�@�:{�Vr�L�"Jx|SBsl[�o�1�.7�j#��qbj���>��)b���T`Nh�Ͷ�%����v�+��¾������TTxC`��\�	������ִ�ڢ��z�i���6��W7���r��WP���Ӈ�D�j���a��Q��2~Qc�B'��W�CG�-��X��[��q]RG,x?�2��R�Jn�C��@^�ƫ��L�u? q@p�Le�v8z�����wT#hߊT7VrK�ƕ�o�.�	O��Om��"�ٗ�{ o�CGBq*��}��/�9��,x0k@�)[cc��ƈ���0B�h��L`������:����i�}D�¥|Jk�BM�g}�e�0^�斀�w�*����vM�<W�k���Uص��]�ב���xjvBH��	!٪�G}D�eЧB���Ǟ>z���T���B��7��ҲJ,��7���G�)*4��Z��G��][6����R4�5R�MT�����;�I�>�?~"�u��10�Z�!���1��#"��l�G��j`@��-�w����+1��k%���8��V7ĀM�?������;x�2L(C�k�0�ݮ
�n�6�Hy!���]�`���*�(7�52��1SԬ~�=}hv������ʂq�50G��W��A�ȡ,�S��%��A��<�|;4���E?�k+�Xʳ��>w�<eF�j����V�S]˔up��XC�z�l��2Hy�\�4-���/�<8��2�fvEr��5��J��n��$�UH����V���i�TI$U$C� y��`�)FV��">dH/Ns�(!3���vK��H��4Ґe�h�T$�L(? �v�!K�U����`I�CBe���X�s��Gb��������?l��`�K���u�w+J�=Py� h7���`;,;�b�}18u i&�?t0��U�`Th'LZ=m��i�plN�x@���oe����~���-`g�/�4��P�X��F��N�p�BN��+�� �
*�v"t,�3%�����}�X%�E2i<�'�)ȓ&�f(ﴞi�Zh�rO�6'-0<ww�U��]ˑ��>Pi�U򹔳�
��˔��'o�Ǖ���!��L�U6�vb'��Y�K��%��P���T���H'^���n�P�T��i ��Y�@��nK�gֲ��TdW䭼��a�Ki��T7f�R/�d�<ڦ�J4��ШҦ����*���Gp�ߥ�.s���S;� ���eP'g���!��Y����HQ��5&��R�*�,Դ��X�t�(���K[D�|,���X���r������T���@�/��z�3Z���L�K���]ˮE�Ϫ"�_�.ǳh9~��'�؀���,��Zy��aZC3����HM�����Q�\�#%Ɋ��\�f��Ǻ&W+�%���xv^/����=X�7Q�rA*����%�oN���\_���A'�B$W�T?`�V ��\�^��Ms��R#� �Bp�r]NW&�4��\d!=����E����:�o�&��%ЇR�I��P�}��Vʴ�۠1�]�(�jS]EHyk���� �ƒPJ��$hz3���:foH�ϯ�&c�#R�Yt3X��%�{"·��=$S��FL��H[c&�Is}��Y��C������ORl��K�$_Lqe!/W��m#���Ve��<5��5��D����~5uY�r�"����H[�:Uh�����1K҆�3���Zub�h�**����[�N�0�=k@��Q#�i��Hn��I���I6h}�&m��y��0W�t��7(��8/j Q0��F7"�2���`��qi��qJ�=��VT��Wă��BԳ�V8C��[�_<��׍��ߡ�Z�!�T{���=�p�+��&�����V5�����8�	�[RH�ߒB�����ؖ5��߲&������_��������M-�#ɤ��X�Z���J$oA#ƞ\�>-*��J���.��
5ER�[i�0
(YiX4�e�����2��&!, �[S��kJ]c���������0k���^��L�n9S��%5�9��r����]��|-(�ØZ9�T���J'��Blu�kۧ�5��q��{���_�Ks�ؤ�)b�5�Bl3ޢS&xjx�:��h����?(��O:�-���B��o^�5멇>�F��o��aii�hze})�L"�ˑ��j�
����}�ׂ7�	���R�J!	Y��`X���N �M*�1Q�V@��h�9���MWs�(���>��m��ϫHE@b�%G`Q����
����]'Nh��!�"�����i�dN�| ��g�+Dj�ҵy�,�4��Xkf	�!]�0��J9�֍�zAl�X���'�/���SMAR�)�p�j߯�f�����z`���L�ԴM��N�j��h�Z����YҭS.�nh�X��Q>�ئبɗ�6IO�R~�$7J(�H�j�  B _n�i厦�R]�����"֠g�7&-A��_i�̜�&��(�*�}x��T7���6ځ���1"@�)����*m�c�ؒ���1NR.U��}�#n��%1�|*f�N� ��W�{@�+C�d���H�+�H����W��#ͦa����[��үT%��Xc�Ac�D��P�4�?X�*�)m�̈́��1�R���y��
x��a��Q#4M��Y oV�>�o̾�l�L2�����s��<5�Ս!:�������^��<H|��D��[.li��[\�4'#˃9���&p�����Z�B4yN���H%�1��lL��y����{�:Hh��j����7�3Q�2
���!�g� |�z��{4�r�_����'� #�T�BХ,ӆ�'#�|��[��B��TWm�	�J׷�����e�*<@=Ҙ椙�h�.i���\m�A� �������]!����T%�%&7o��m.�`��g�-����T׼4�+�(�CyOSѹ��hQ0]�h^0E'}\z�C-�'����K���]�y��_�!ƻ(;F�����5��>Y+�`v�^���C�V�Ҧ���Mҩ�/�g-�Za����qg~�|/����tI*��Q&5��KRI�y(�0���67���D���(�U&��&��43S��b�4~s�DP����Z�Ub��ј~�Y}��_�?�w���z� ��[��t}�1�0t�R�#��C� �TUW�u�\P�m����.)]����	"��U�ц,k�
�R�ޅH��t�E9w� 3>pdz�q�â���VU^��ظ_!�4t;4 $0,g����<�(u�p��=���å��A���ir�Y��"=u?��^���Z�vkm������f�,F�(���<7IE�{�F~0ħ*RQ�METm�a`S�oJ�~�b��iCwtO�z�k�x�� �m����o��M����V�B�r1�ۤ�Z[��JGV�L{�Q�=�/G%�剷�L�3X����5����w���=�ԥ�L!�	�y/�$	P��ޢI&P]��7��L���>��[�L��^��R�M��R�٤��(�S�� �j�l��<(_�-͔oK
�B��MQ9r�]Lu-�n󡴨XT�ħ>��U�}�/Ľ�M_
QPe|Ij<м�Z�C�T@w��n*`��y��S\�McR���5y���b����׼r^S0��@b��r�"�dX� {�]P��ůP[��k���1�h��LM��X'�A�Mb��3aE�����N�4��"@bs~�J?k(ScR���-}�_L-�bkLK�Y��)��dM^�A�θ��i�.���<�F�oFq��4֖�k��y08�M,K�!5�&�לr ? dR�S��HFL�R��VX���^����>��I��{j���[�J?sa�h�Iq�a.h ,���!��Ʌ�H+ӔH�@ݼ�)�LT���д�����*��	O������o���yA����:�(�I����E}M�hz��с�?*,��?�F���,`��Nބ�Y��T���>N�����*o��<s=31p��IIO��}�}���Z(�$���Q��'>�O[���eJ4�����l�LY��ۈL��g}W��v�W�UB3�ު�QwB�q��/M�(r�l*���-S4~����8�k9�E"�*�}دΐLk҇�uYnx�ki�ޒ�Rtށ�6y::A�NA@�:ޠ��E<����92��љvO�mx���-�����vEo�2sxQAda�B���q|�J!"�<ژc�VW��	� ���r�̈r������]v*-�l�L�������Q!��>d�Cm���`Fɢ6`\�/�]%��b��=o� ��[�S;m���"{����VT%4�����nB�����c7(�EOr��G� ��bBN�L�y�k!v�UH-��A/y�M��E'} ��+��K�m�>�v�j�� �r?L���SF�� F����|�k;ڋ�����؁�y�$�����V�Y�pm.�SvIj����L٫�-䕇.eث���Q[YOO}!���Z|�v�b��:]���q�No�~��r`4�������<�-��M����;B�zc�u�H��x��oj<+��#WV�+K��ҝB�,s��N�k��ձ���F��_��	�Ot~
PpkJ�Qta�r�����`y�>7�i+�pE��$&U��Ȟk��`�%Wt{���b1mDb�+J�ꇌ��j�	)���sU{b����q�>}<h�4d��l�߃]Tl�>d�,�3�(��Ғ�`��46�n���G����"z>2�ʻ�y����c�!���h�eE���0]B$�ر�3�j�L�Mֻ;�����B�i�e萣�==O�J��V�=�ڣ��8�;;t�N٭S��[�Ԙ������rB�'���_�M��âDI�n���B��M�q���(/�u^u�CRC�MS�r��y���s���� 6��*�w���D�� I�jn�NM��gf0%�4h�ü�%�x�� �TX2���qf�����UMλ]��r��z�*�jj�j�ee��� ���w�ov�uÍ�L��]�z\��4�R�q<ܴ�1^iJE>5S���Lo$6t���Ak�Zd�m��l��>�y�i��т��������wN㚩q=8G��>�I���S���*�z�1}l��h	���.��z\�Ξ����^u7�G�z����w��ky7�?Ġç�ф�e:��YI�b��e"�nV����s����yo�a��i\����x8<��(�� �
�m�ͻ���yg[P�Z�NA>�u�0耈��`=+�s�{���<"h��4_����hK0�r�Ӽό�R<W�� jXΚ���,S��ξ�����Y� �������)ςTL�r6�a�EA|���h��6����]w2�O����X�4�����s �K�4�LCF���@��U&2 ?�����0�73��Vk��Y��P��[�� �90�iZ�k�R��hZ@N<�I�^���6iZPO@}u3/�Ը��Tr�#�*����`�rT;1�L\@OG������0�_T6i��	�~d�h�<u�	��������6&���ɍ�^zQ�]�:Q��,4�k�<-�(�I-��ZK?N�R�w{�bh~2 ���~Κ}�:�Dq僜g�9OMM��Y��}��^�]��S"s�z�YЏ	a=���L)b����5-�sf��a����Y�!%�Ū�I��.q>�K3�������3�4ȡL\�٦y��.�pP`�򆉕"9z�8'�M�@;&u���kߢ�R:��|-��<|�����z_/��9|U�k&�f��1|=����u�F�_I|텯}�u ����P|��#�u4��k(�F�_��u�&��t|�����u����2|]����u�n�W>\��?�8�_���_m�0g��J��O�Y�=*,P��`�c�K�z�2��'BѼcES�A�E���I�elFw�����V-%�����o��!��f���J��;mB��$������qu+n��)�M�߸W4EeN�b��`l9cΠV���[�Ě�%�^��gwJ�eg���8����K��x{V��s����x�AS���`��7�x�����#0��_��N(Q�/�ɤ�+(Y挸F:�L2����d�p�1N�𕅯��vL��&)r��_�"�δ�)����*������>�}������������0ơ1�_�3���!�n������~��~k����ʳk�1#~���~o��Xf�`��+��s��(�E�o��A�=������~� �
~��Ǉ_o�y�o������7~�'������~��3����o���7~Q��1p�q�8���q �H}�	�- .���%$:4$6��1dR�$.zR-> &(x|\�����#Ə�9�찱!Q�5aD��D�F׌�J�ntl��Ę���Cb��#k6
�@=��Yl`�����Y@p�o��%��Yd|�o��E��(P�>Gmm��gA�k�9�VXT��jo瀸��Zk�X;@g����k�4��5��F|D@Tи�x���ާ���&�z��Z��?9������Z���p�{qj�	��D��?.xl-p q��A�S�
�f�ظ����Z`�Ƅ��a׈2�6^SK����O���TKY��@׵�%���S��Q������p �k�O�Z�V#.4,(�������@���26 2��>[��F����������W[���xgH̘���
�F\`��k+K ]��e�$D�VOĿj�#�q�!115�#01��>B�_���5����p��B[�8!��Ւ�]K:v�t������o��WΈ���M���k��aQA�����e�	�~Skz��-�6���a��8��Ղ�����1�Ǉ����8}-����8��>QK}�W�.Ą�F���.�a��%��1~|�� �QS>�SK}����cj�T���ؚ�m��j���Z�0��ڇFj�3""z\mc?ć�&>������	�-}p�����a�j��d7�Ƙ���6���pRc\�_C�B^�t �U�C�c�8$5V�C|PDX-�dL-�=1��'����z�A�6|P�Y�����P�Qk���<��Sk��7e�����x��>��X{�W�Z�q�%�6]3(�v��&��.#��.�{cj�Ɂ��W#��P3>��!�7|/������M�x�o�k���	�M���~a1��������C�j�ST�D�A-���� R�]t�b�,�/�E՚�.gPdtĤ��I=���P�X���=��}Գ���Sk��>����Y��}���׌8�����x��t7H\+|H�u�5���}_|\ʚq5h��2�9��VK|�AP�Z��&ޥ��;ćE��v��?��2�c����? &��!=���<>>0"�A��-���VVo6>��V	���l�B��Kq���u����p�l�\	�'��1^�cCmh�>6$b�CL)c(���ތ�����U�؎c�����萠��`[(M�$��4l���G���v�a�e�Ge�m������������}.*c�� �!�x2����{3��b�����7x2�P,�e����x2���p�+��������o��w�Տ?�Q���ړz�/�g��4\�i?	 �qh,5���\U-_�84�W��~�tHF��쀣��Wɏ��qQ�8�a�>� .GN��d � �@�wEF��!�
���2(�Ūԁ���'9���۶��>�Wm���X]���+<�ڻq�.�0.EN�QN�U�8L����Lt�Zy�_��_�3(������*������?.$����|�@}���O��]>�r��������r�.��~A���/�$��_����c�� C��;��q���gXC���r��q����gXC���r��q����W�����r���K9~��}��O�V�#�]ު���%�_��|������w �	^�"oU^����/x�]�j����w �	^�"�Ay��O)����������s��|���G��yb,��r:.;JX�\�W���y8�GW����V^H������p�*����������_������U]y���Yy!�.�����<ty�u �~�{u�W����vP��K^���p�*�������j��?(�����<���H�A5h�������U]y�)mՠ�P����Wy����ף�W����ݿ�U�yt�
k�wsr�����@��n�N���儘����O��o�U����O�'ʧ����!�5Y�IU�\���}th�Cd����[{|t���q���TJ��q�5�Qд@�9��]m��}W�3B���Q��GB�j�Ck�U�	�3��S-aa�L�A�a�a|�`r�2!�����6�����a�h����x�)�JZl7a��Wޏ5��2��e>���8�az�� �az6���Ʈ��0vH|�q�=�T{�l` t�8]�a\Db�ô��> 
��ZOl�C?�L�|�`��P�=��5�ur-q�Z����V:.<�����U�ݸj�Ww��n��z�l�j�	l�U��Ə��ǰ=���aW>�Q��
�qb�ʮω�[�H%��9Ql?g ��qj��W�>�l_��rT�dr����U�U1c�pTո�m�����[YG�X��3�*Rd��ũ���Gq�*q��������1���5��n�j:d_Z����Uǟ�q�}�}�C�Cl����&���٧����`��j�ӑ��>�Bh�a�8���v؀-��i[c�'p�}r^�_�O��l]�~؎�f��K"��s���r׀[#Q`u�4�_B��@@ˏmӫ�
��/h{w��C��8�����2֐α=���CT���CT���,l���gH���3����Y`�o��$P�&U-c@\�;;���X�p|�~��8���Cm��>
�IA��8�_����kG�>����0�`���@����4+e��H7��Csrp
�Ȉrp��rp�?AU���������)�4�n��?NO����u{p읢��(���D��k2��9�?�K��`�=�q���[*�ُ��(Ԑ�E��1����{V���&�Ԑ�P&�{� �����C�wM�ԉ ���ZI�h�U��ڣe��E%/���Cl�X�%U�Mj�]��E�B6:cTڞb�:b�m(0���ؠ���ۄ����X[h���1��q�m9��p1�cQ�P�bi��1�����5�jB$+��`[$��J���Ɨ��1a�z 2: h����?>JA�)$�uփ�Nzc�*����=�t�Y���6[�ί���$2��.��`��t��*:^mn�mn�o�������]uGZ�:�X,�ҿ �u�Go�G�CE��!k���yI�G��C�>W��`�O�(�����g�Ձ>O��"t{)tƈkV�O��c��%����Rg��k[�v9�|�q���(�'"Ctj����a�_^l�����d�x�,��Z�1u��:CQlDJ�/HWa��*|b�-^�jCg�D������?v%"u�(���NT-[��P��H����Zg����������~'m��z�m��Ej�O:����&=��kk2Rg@�?�t<I�l]>�}d�ު}�Hd��3nC���0>�?�vt����(��MI�R��D�?��c��H��TJa I��q�yDN���1D�MF��O��\D6���7�g�8��t���K�M�	�ћ�3V�� �mV���/�LG��:����mnh��z�A��4����t�&t�0ª�����t:+R��C��c����E��F��#i�o�zᐂ�����=����	�~ZU�>�c��y��^("��+�����!���zv!�?�-��X�g��b:]G��t��THN��$�ߜ�ϥCN����3�<��Y�;7n��b��ޯ�^*��m�A���� ߢ9��� �"v��d�v#�K��ٰ���w�k?^'9���{�#"��[�/�	ݦ�耘���ۈ񱘓G� C��抌��q�>���l|��/���x��&3��G��5.j��(F�X��ׇt����m��m��m"�����Pm�3$�Hk����[L�6��6�E�tmЧ�rոy*n�e,k�U@���-�Oӯ4}l'����x��ZHFқ�hE��j=��^�dlʛ��Op����a�n�>4��
V����|�(8�é�Vg���MR�y�~O:~&r�Hz�a�n3"���7I�s�S�P�n$��1�(�3d!�C����7{.Z�����ې�۰i���fm�ޑ�Q�}3�v�<g�:r��S�fS�����f�)�xB}����'u�m����t�>]��}�!F�c~���F�Ȳ�[{�7""�u#�~����t�,��WW��Xl���7{?�8��8oɪ+Z)X]��_����ʏ��d�|�i���Y�U�~�;$dɢSN��q=D=Цm�3K�_b��uh������1cC���1t�u�u�1�:`=���`,�E�������M��~n����ȡ���N#�EG��[�~�`�AC��ns}߼�]��vuJL7I?�t���\|l�,���Y_���:�c�vc�>�:��-�S25�X���7������1c�A��cB�0���w�{�>���W���\��&�s����ؐ8�Qq!��CL֧���4T���������ӭ7���b����Ć�G���J�GČ��A4~��J��h*}���r��X��	���?&�K�ҧ	���\��ӠM�����B�<�x���&:�[Y���H�Ө����c``���F���2��bu%K�����P��>嘘�M���Ȁ�aA�-ԻC ّ�h؉�C��F�r&]���N�G: c�>z"�|k58��B&�G� ���e��je�
�8��%�7��6Ti'P�qCM4���T�n�:�x�9���=����?�1���0OC��bstB�aN�1  ���2���p����)U[0ѡ�tt����`pd�h��7>&�1Ơ���࿀���Xl1Z|�1��Ʊ0DGF3����F6��[�#�L����蘰��1�|cj7�hcj�i?�I�e�<�]��/aX����d�g A��������[�� �944&$ x`X`L@�d(U,c��A�yTQ����D�uȟ�1���h�M��Dl�s����h=��?>�)���T4�f���>�}�������������?l��Eb	����3���cth�ɬ%�~��y��c���yt��Z`��?�M��F��\w:o�Z`���%��Z`��#\�MƬ��˃{�1k�
7S�lf�5 ~�	��}_d�:�5�}�����Q����O���t��A߯��|�oԘ������>�������P�?��{�����P�vp��G���p�����K���u_ ���?���G����6}�3X� �f�" \Ђ�r�puK�����5��m�� c�ڶV!�;m�s�h�`��Q{k����8;2X�!��`��p^�ᡮ ¼nP6�,�hc�}+£=�>bC� ��\���I&.��� �e��d)��p��B� ��Ƭ7��0�	�B�pa�6Ah����+�a���0�}�^���`9@hޏ����a��(ck �����KZ�1X� l6�B��V"�-ݡ��x@9!l3�	�pO��C,so{1Xe~ ��
a�a�5���B�z$�B_?+�� >����P/����P�`�!\�!\�`1!��`��4f�`�A8q,����8�´p���q�_9���FC�!�1����/��b,S����#�YI	 ��.��'1X� <0��D(/���V0���1X!TO|@:�����}
����(�pc��\���:�p�|�!��p�B�aH:�B�Rk(���,�ˡ� ܽ��[+�. ���ט�z��1� ��l <C(�����@�~��`����6��� ±; �rC���=̘�a��{�> |���:a��:�d�fAx��7��rC��(�%��>�v��@�V��1�H��0��B�L���lk�M��t�9��� ]@�<t��s B���� ��s�Bx�
�B�k@�N�p!�t�Bx�&���[P^m�By!�{�B}�B�p��.�.��By!���B�g����c���'P^;>��B��9�����!�\�ܡ��7 � B�w�����p���� �A��#����g(/��K��ʾ \��\OcVF����;�������'��0��B��Ȉ��Ĉ5�<3#�u�X6��g�2��E}#��!@��F�\oX��A؆e�Za��k:�dS�a���/��m�X�nk�bA����U���d�ʃ0�ވ�	�.F�]��f�J��mw#�$G�xv�@� �Ń�A�%��AxThTmL�D��$�9��Caw���7W]�?�Yw�5�G�z$~#���Э��!u�n»<�yE��'n��MK�7&S.]�d����9J�Qa92�o�e�t=�GZ�t�:��2Kv���j!�|����S�i��'�ğ;z�%��,x8Gr���}Pi����+��KN����Ozv�Lf4��b�}Biy�yZz.�g�0�?~�k��X<#��!�x��}blz˹�M���O�Y�l�I�����O~n�/"�8x��Ͳ��4�.?�q4������3�t'7y�zn�E:��ؽ�2���53���w�_�؃���by+Ne~�ށno�>'nv[�?�;�c�]ݬ���˫O�����\��&������dr5�3\���>��{�n��G$s/�;8��j%ú�U��#n�WyAd3�U����Ȟ_s�	�y�3'�;Z��cl�gւ\UJ�����gD����r[�S��yS�i��V�Ou7����U��M6j�F~IIm����[�+�?�Q��=qy��E��}�������h��<�?�>���h>��}׌9�ejՊ�.�i�k&ytEX;�����׺����oZ�n�������?	�ѭr�S�xU�^�#�jH����^��6~=��㕪A��o^�R��J*��[�^��h[�jc���B;U�й����ooY���tH��w1�ѕl9uR��>$��غ*ӑ�]u��%��d���%W�|%�7=�o}���c�f!}�p���&�N��'O٠x|����`qB̸W7�(��:�X|$����i��{���]7����sr<D�������DbK�R�� ��0�`��R����\�WLy�2iۤ�rrܽ��6�'�ZP߻�#;�[��I�x4�� mS����9KR��w�k�������L_G����P�$�vu��:���zO~��@q�/i�婋Dr�����[�Qv��>�g�l�a>q�W�Ƣ�����yS�$�w���Vك8�x���v�s��B��W��f��դ�$��]����dFŵz���$�cܯ����S��6�+�6|�nw�h)���o�9�G��&k�G��?�(F���V�E�0�k�G�/T��۝���CU�AԴf��T����=S��^`1��)���iC#RT�]��wU�8_�gN){�͊h��V;#�bn�Q��&ٍWկ��DrE�]��[��:�s�gˮ�3>aMnӹ߄������?�t�x��m@�ձ�Mv����!>z�S�:�H����+�̿�`�	D��
���sU~���\lJNM�����V�.���n:��w�F��[�ކ��N�����z�� Ay:$P�^U1�;:��WWX����j�ƅ��%,�|�]R��*\��ԟOZ��{���Y,Q�f~&Se�?�[>	�����$��/g������ǡzc���F�b�fOPu՘�m��Lu�JYar#��i��e=ګ5�/5���L}�M��#�]H�Y׌���%/<��1؃챹�U��$������oUS��1Ԟ��5�'\���xʬ�*c�z�[��aBw�l�Ոs��d��.�M��4��m�S�7�5!��ɷ�Y?6x�����	i�Ǵ�K��_�����=��%:�����{��~�dR�	�9�Bݳ�����y�ٝ��'A���6��q���������I�E�v,��VƤ}�b_Jȣ���|��"������ ֻA;E�ڕ.��7�H��#��h�.��?3ֳ{X(65��dq�P/�'o揃��u�o_V�M��i)"��.z��� �ɻ�|�n'v���Z�	����Q�O"Oɏ�wX�B�.��ET>NѤ���q�㊭����.SJϵ�% ����/� �
�[�~��t$��9b�����]Y	���א��
	����m��T�o�bـ�D�nyP`�
U����+"�}��r͔�bط��Ș��(���L��0����I��z+�o���p�����b��S�B��5�x����V�dǽ��?r<{��A�]4[����_S�O�"<׎�z��N���.>����-Z
�G�a|FuGn�agE�W�Tdn�t��bP��=�T���=��i:�|��ׄ�YB|�7���Cw�3q8��X��e�ln������6m&��t�U�=ǯekG�2�NI&��v|����p�`�峉���/0����䇾�iă/-ތ=<����6���;�|�%M��J�Y���n�b39FDD����w'~��Jk�c
�~G}mC�ń ��Q�k�Q�L���|�^�l'���e��b?q��ꯊ�D�$�$"�w���i{����K�C�:�<{mC%{1o��&�	�won��L����c&ae'���r!��Y��6��7?�̠�/���/�m��R�9R��Y�Ft^�׺��$�����M,"~���e��UD��ٛ^=�@���|j�[������+v��G����m�P9U:;'=|������W�o�٨��&a�=.+�0�Kq�sW�k~]o�/ �]�;�歯'w����s��=�,�3����ٔq�I��MN>��d^���Ջ�9���Q�K�g_,BD�&r����/��8{�!�5y���6�K�y�f��+��#����ɥ	S�7�\I�F��|�1�<��]O!�0-�LwiܢɾGc���f���wG�~rs��CjųE����ϳ�X��^u��M�tx��£d�7׽�,%���<����zmѢ÷$�N?r�ww�O_���\�#�ڲeT�>@��,m{���~���O/�$�W�^d��I$�����T��n���oy��|��*�E�Eޚ�����B��v
ǡ�ï���zm���$��f����܃Q�a�.m���n��]�����u]����g;O:4�즈�8�pD{3E؝���fhU=�2q�z���7v�i=���q����6��������8k�Nı���n��Ϯ�6Ⳮ�t�s���v5����gD�����͉n�}$\�[�Y�n�����'l��v˵�6N�D��e�I��[p�d���CF�=�u��jO
��O���M��Z/�-Q��Q�#:.�/<B�4_t��z��g�j#�7��r>��m+�{O�W�
Vv^�Cg�dK^m}��j�Ƒ7Z���r�ڷ��[��{���IW)5a.�f#^���Ӱg3Ո6�Ծ/.(O������=x��OU����{��Rm�к]y�o�ɉ�~w�J>t�g�5�4���C�p�́�o���wՍ���`��1�\L\z�/�p���#%&j˳{4[M�^���d �lҊ
�f
bo���-��d����JqAa>�ہ3`1k�Ԧ�����M(�v��^�$�xx�:d�nP��@�j!_��|'�tֻ���}U�G���hL8�3n���+���4����W���<��9+(|�J��w}�!�1����==�u"�X��?iJ4X�����*b�
����<S-_�*����cL��n�j�Iވ�a���_k�}�n��8MR�Duuз��D����¦�U�r��ؗx�h7NWu�,����4��pN�C�����s*���qO?8 ���)8,_��B��W�K�!U�ĺ�tx¼��E��^y�-ta���OOuaw�>�T�b{�x�ԾN��߀!����Lp���^k�N	Qث] q���ŵ8y�Y�q��>翜�2�ul��v��{��9w�ǫ�-���z�yO�m���{��~}�����[ӧ��WEyEYEIEa��bz���Q�(c�0
j�tT���C"���T�a��<wsG�w~��]waί)'F����in�T��Mvg|�^��9s�sk.�l�r��u���_�ǚ�f���t����q�_NE폼
~e�|��q�t����³�,Y�K�?W̙{�������5_V��R"}�|ѾAW������CW.���7y�/�R��c�1��t�u���)��?"MH��b���r���w8tk���Ĩ�'o�G�!�'5��r�\����s�����&1w���{|�h�靫��o[ �����G�W�b���݇o�}1k����4dJ��_�Z")�nN��,����������mG��]r�[������x}���f_;+O��q\��<�tH���eN'/�p]z�� �BbF\��=��	+֢���譾��{��~�6��V�x�7��)�zŌO����_M3������e�M�d;��~�{�C�-{p�z2B���!r�Wb������G��#zըl5a`�e�#���u�;�Q�Q�����HT\�([��B��|�˘X���%Q#_�R1k�p=ۭ�d��{Us^=��I�zTt�g6q��9���]'�@��+D��K%��O��p�c֔�eٱ�v�������2F��p��8󈱏��}�g�:�oY���Cv�r�~G���6�����X��7�Z?"������P=|�n��!���W��8!���K�%���Kۥ�d�^g�U�	���ǳ���N�*��hԟؼ��k�@�=�y�Q�r�����3�����X�U�ǣe�ffrr|ja���3��z�X�9G�����y�:�bO�z��������0�O�����g�����O����9�|���wć\~�#�f�nOZ�K�;�&�x���S��,�{�XV�c�����:w�4��Z�����������}��W�<3|ٔ��G�X��k٫ʽ�h��Q6���m&��{�|y3 [�>A�H��~Q�����J��SQt�~u���پ�k���[���ԭ�jo"+��q{bHqӶ?�9��Ϗ/N����v�T����g%���a�*U���n�W�&���Ώ��R��7q���D�uu�;��[�v�$Z(�=�t&{q�1{{g�����:;Uv�it]��ً���6},S�����@Ff�o�&�"{�jY��ekC���eqO��\��9����E�w#y�:e���:}��&����%}Z֧�ɂ���:�I��=r�3�{��Ǐ/U_��P��~w�CwE��ӗxSD\ϯ;]��s�(���%Ő�'m�lL�K�e��q��z��fV�̼��~���gs}&e�S-}�<h�,��E�7w2ͻ4�3���\�`���@�,���}&���19�;#k(���g7v��-^i�q;+�	q���L�j��VB�l���xa�^
��;�fl6�V�����Wt]�2Y�/���F��\W�<�8�۽����7�G�Zv��^GUғ�]&�mwe�S�|��g�	D��&�7n�����������������d
�=�}���"��ֲ�����u�%^i���
�����f������=�l�1?Ӗ7q]������7�=.����������)�(̼�c~���?fj9��&ԕ��?�Ifa/��>�G��ͳ���.t����Xxݧ�aY[7�|��z�|��,�-�<dҰ���������Vp,k����+|�l{��5&��sz�^��42�e�?�gǚ\���on�����O�i����s���U�ǭ�h�:2��v��C�����IW�[�'n��;z��X� tP�{�	�zS�~\nJ�[E�-HnGn�l�,aSRǋD+MnL�?�x>t����ǉ�u�^�iXJ���ϳ���v��X�iG�pt~"���_�]��g�*��Q:�Te���ϛi<�9m��n>�7�+��c��%��N	T_�>��X?�f��[�x��}eN>V��u���'�/�˺>� ���!kb�L��4����'ș8{�l"�ַ�ӓ�"��Њ�n�+��-��h_2�(u�u����g��;+�ys���Zޭv��Ϛ����2UX�w@���?�#}ڻ���uw'���dt+�#��!���9���;/��|�<��s�o�Vj'����2�o+]Nw�=�G���xM��&)Ȏ)6�=>�X����11��+#�����c�ae
'�'V�0�L#Ƕ�"�*4s���׃�b��U�^��3u���:�hv�sQߕ���輮��d'��.�����>�r~�Á��Wr�-p�85d�s��k����=3����ݺ�����������,�o^R0�h�SΛS��Vλ*����ٿ�����:.3��RUa���Kt��]Z�Dt�֗��ܯ�}O!�hz���x��\�٬���&ߖ�2��՞GV�v��j�6ÙH���W��0q��{������n`E��ܢ9y͖�?�Gs�2y*z���{���"/ׄkss���!����>��&��Q����!s��'��I68=t`��p����n|	9�=u4{�r��-Wg��3~�l6�(i}k�m��gH+����*rF�c�V;ȕ��çœ����}��S���a���`����z�Sm�,��=<&����s\�w{��a��3S��aKf��>��c��~ߥ�f-vJ�:.��F�͖��9�X�<�M����������(�iq_�?�_uq����ͯ;��3��ھz}X�j�)B��xa�q�p��N����V��w�M���/|K����XR�<�7j�ݟ��[�no|ړlnt{�dg�6���{��dU�gT16'��9��<l���3*��3���1��!���J�qp��f���-���S}`a�&K���-a�>x>Y]:E��ݭ���dV5]�{�{���#t�K��*x�ݬ��s��^��I�DyX'5�f.kG��u;���=�L��2u� �+'�H��hT���yD��)�\I���[�􅍮��	'��L����lɗE�d���M��V/.h�Ϻ�8���A7�Q���=�>׫S*^f$�ȵ����N���>W0����ŏA���<�� �|��%�H��[f#P�U�� �}��f���<N�~3M{8-�l�q|a�}�'�k&y�cT����&��I�><眪A��i7��_���!p��7U��j�'��VF�TŨ7m�|�1����n空.��e�e�������s*�2��%��|���Vٞ3�����Yޫ�G��gvț�9��H[E��o�3�+6�/����U+��1������˸-�Iy�y��D�/��ƴ{�z�a�����L:�Xz�WLf��]N=�-�9%<�[�sW�I��}{tV&�|���0sUAR�ui�3��N��j������	巢���X64�c���[-��.���Ҭ���}����˯o/r/��e㌈�e�Gv�t�K��΄ɦ0g��OC[5������K��XOz:;{wt�5���y��+ت���,_��K��:����Tu�m̚mBz?���3W�L�м�t-��Ǐͺҩw�t��\�H���|�{�8;�m������TK���/]���{���Rݵ��j�}�&K�yl�t<��`x�Q�RZ��i=�y�1�����G�ia|����3�f���n�3���N�!�+2C�6�-z�J~��ջ!�$Y��7���G^6�<����,�`u�5+�So-�w"+��6f�w�������A�c��n��W�t�6Q��s��$ގR\ؾѐ�+���5����/�\o=��4{a��y�Vt!���;l��G��o�kN���yp֌���;����3�Z��x�B4
[�����d�bŅ�
��Ҁ%�?pȲ�䤠{mȅV�]ډ�[rXߛ��괕�J�;0���e�HǶ�ۊ�Y#
佊T�ǖ�Iۮ�թ箮���⾓�ዮ��ψ%������:�M�_^����h9|r���O��q��-��N��ݗ�dAAqp�Ad�;-:65�ds�n�#����h��A^�|�O����p�ۜ��#�R�4�ǒ�i]�='/]N4�����p�����o����:3�]iƬM�[�y�K�_0���or��-v�%�y|ao�N~.��cχ��1���[�ї�j[�{Oz(9�f�E���<~\�#?���~;A�t�h�֯o��Z�ğ�⺒!�O9��"-���L s���MZHzL�V�e�:�����}6���-1��l5y���h�?�^��q>����R��Na�&V���fX�m�d��+�nmM�5�S?�n]�ݍ��қ�?�;�=��`6���sں��V2�SО+�dz�?�?�\���'j�t ���0h�o��X�q�f2�C��s�i����z��S;>�.��{�V�����?����0Y?�Ȉlq������N��n5���n��w�74�>�<��μt��9�7
���W�,�x��[�����/�Ϛy�1ywFAÕ^������ꊫE�<�ad����3����Ms���I޻��^���J'�?Z([sQ�"gN��$rA���p~�l ���{֠��IEGFu'7�"�H��ȉ+�z}�Q]t
z���fբ�W#[T��+�<|QOr|����Gz�6��_���7w�Ŧ=H�S�]�뙒\�G��ygT��F���UզN�dղA��{K_k_�#L�|�����P��fZ��k^[�����4��˄� ,��;�hl}C{�,��7�e�ŷE����9*�J���d3��=n�$#�`�>�/�Z�}����ʋ�$L�T�t�& �^��y��%�|\B��.r�nw���V?zB4}����9�xҴ�kmȸ�#�H�Ә��v�=��?/�8UTHI���2��d�����WT�I<L߶�����m?
���#���Y��-������o����3�+"m���r���kTk����>��о��{_���.�zA��7���s��	N�_u�����)�g�T�$YF�S�2�[İ��u];��x`�.F6���湲��x,�#�>҄�Qf>s~{p�K���L����Y��'��'d��O[��Aݠ
�%壳{��?�����E��}��{$�X���s�>"��̊,������
����b�M,ɩ;���=A�2u�o�n��J�>�G֓�3en+�����R��9��sn=��Y7��i��<�X�兺��{��&>J���h�prY��]@���^�̗(�~eXz��b��	L[4U-�!6�w�A	7�>Q�nq��FR=>�$�ܸ8���/�Dz�	�����g���e�Y����|5��L������MZ^�#۔�����Yn���l�L��e���"����N�Z��P�����_���=w8k���7��j��u�C\�+�+��d5�xҡ�NA��}6%�S[ݔ'��(�q�������!�`��>K���jNL�~4�ϕ��Vǃ�v��@۵`_ߗ���f�L��9�ß��;'���7���ZvP2�ujPF�ws�F�g6Y�q��e���>����2��	�㝳�ԍj�lK�{J�߳��}�|�����L���v'�l��--6,��2����{n�f��w�ȧ�m�f����4D1���`���rńK��UD�L���D� 6�m�[!�~�ޘσ�+�w|�qE	�kҶ�3�m�g�l��ܙ�Km�:��ߴ���̎�a�m�d1u��"d]����P;�����B~�<�i��sS��7tt<<)��iGMd�<y���`��W���M�e��_Q�8Pq}W�6lnX���GڝK�n���霧Z������̍�FY�T��?���W}��4�?I��77���Zb�Ӂ+���H4��h�}m�,z�/.?'fz�;?��|q�mnѩ��Ge�gkQ0@-c�/r-g�4U���sfM���:�ZG���Ǖ	�豺����G,�뗐5��ş����G՛����`�BE^��\�v����Y_3=R��n�mv�g���r�.�d������8N�z~����Ê7��l>Y�Pm���.-Kn�t��}�N�_�F�vtS��y/T��q�ы^d����ȝ��Kt���5�����=�!w_�!�gSE���c�;�+���y�MK����k#Z���-_4�){�!�Q�yѸnهBƌ�����<zm�l���\�q�z]zU�	o?�|�X�}j��]]n����{L����u>�劻C��{���^Oip��G�!�}٘�M�݌	q��#��2&�>O%O�f�r*1��x���6DGR0�t��˶ډ	Cm�Ȉ�ڃ��䃓c.?�ILKh����{�$iYV"��jyA�<��a�8����ڲN�5D�A��s�"�>Kc��u��6yˉV����KZ�-��v$���i�z�Cz(LMF9�|�/_?��f��T����`�;�w��_]�\ ��h�mm�Tb��������N�yWQ��Ǿ
rM��J*��ӏ;���d���ω.'_�3.��N����(��gML�b��[oJ;ul=��j���-���A*��d�{���w��6�%ѽÕ,��D��7'L�L�����:�	��-�9�N�ݼQ�+s��ϻ�"��W4��x��n^�����ē��i��G�)-O�0&�[���Rqc�t��ޭ��f�}K��2Y���l����ٯ߉ɍ�����v�td���5���V��	I{_�*��Z�c��T�� ;�iokEb�Ö5\��s}ݭ�?�^���v�������}������0y�j�ɨ�*�+�q�K��Q�m9gS�ﻲ̈AS׿o��0`_���%����+��^�5��E"�UDm�{+�=��Z�[K�s�:�_Tqd��]ENÛ���Q�X�7�hq$�eJ�.�]��9;߷�ޞ_g!�C���A����G���ʡҍ��C��~�ʓ��\�}����Z�"կ�Eǉ���/f,��6���Q�IMsf�=b�ڵ���S;����^ض$s*Z�ߙ�$���z}M"BGz��!Z��
�����n��ٙ?%�C�Fd�n����*!~�p!f[o��m�kL��l���m�����#W|!�_4KK������������'���h�r�LL����Z��|������]�i;!'&����W��]�ev��|�{sfQ�D'��lY��Ԝ�k��nu��sψ������2�V;�V�i5l�'�H������ͤ���������2�)-m��>!<�����ޒ�|r�2�HNz�"2ND���Y�p Y?euw��|R�H� ��A�����P��GyzH�8r;��2�XrLa_�a�q��^cz�-���]N��nso��*�Ӧ؉+ٝu���<�W2F�@����W��{�����o�j~l������`��q�m��	� ݧ�p��'<��`��3݂ҞzL}�̱?��������g�p����W�w��_��ُ��qn��D}����e"eVҾ�M�'V��h�v���g}֍��bQ�"�,�h4Q������D�˨�܉��]?�qH}��v[6qj��K���O�}�ߐE�k����z²���(f�	�e�*��-�l�����Z�fL/_��!E�GN�flR$]�1f#]�`v�E~��Ə+|�h�{��.�ъ�ךm�pW�2O&4f����s�3؊�-G�[E�����,�P���<���E�9^Q�����G�v�)�}vzw!�[K�cNN[LW���Tob�훷wz��nt�����^-&z8��9>M�=>�휺3�X�0{�c$ԭ����{����ǜvǎ���f���w4��i�qx�N�7�g_���3-��������v�|�/��ݩ�/��Z;����ݩ����4�~uǖc΍����4������t��T\��r����~�ͦ
$��lD�r��r���n��\�Ϟ�3U6*'c�&���֜M���S�7;�~}��8�%��Ց3��U�M�[rf�
7/Mo�Y�����uY5�j���a.�F���s�ٖ}w��wO�$�ˀ!̞d|���a��ճ�J��l]w���߬Ǭ���1sw���/>��(��r����;�7>������d�aͺ|"�7�g�ҋ�_N�Zn�01��׶���N���׫u~�t�K������9���8!S��ws��[�'�ϭ���H�?������]���f��~�������qJw��ןc]_���׋�դw�Wr�}���ϯó~�~�S��_�0�?5�s�<����q�C��Uye��/�z4 �V��t՗�7���S~�*�z"����v��q��l��mQ�8�]����ܠ����v^P������o5]_�_�m��:�~9u?=��ϝO��C���Iݏ��|��������^�7����7�L�Q���tփ�'���]�:L���1��䜻�.��-�q������^��w'��/M�B�-ht�!�9�ky�6W��Ɠ��R�.�X<�7�~i��B�\;��f��y��+�.,wB�p���e�jǉ=^�}Z\��/��xyj9�xd�UC{�7���&"�ܱ��:�đ�;w/�����r����T/�n�?�I��2���u�^��d���S�P����&�����x������\��h��r��+D���bҙM�w������Gӧ��M?�������@��a��.l7��
�=�v�=g,g���Ǆ���Ur�s�rs[�:���yy'ye<c� �<��@$:.҈��b�8^���S?Hme;edf��
E��L1��J0lA���e/fs�rNp�r�p�s9�@��'��`�0F���􍬱�^HY��;�s���ϢdI�T)� 笠��c��7\�\�R�	�[^ ?������$P
V
NJ!�4�ja��p�h�h�H%*���׋s�_��$K%%g%e�H�厛�;~w/])�*�(-�N���m�]�������wʯ��x�z�n�u�11��H�%nw`.PS�d�f�~�-v�T�V�A��;�����-�j��^�,�K^)Ϛo��˟���o'`�
Ff	2��0B�.\'T˄D�E�D�Dy�r_|ձ�4B:U�Q�WzSZW6]�KvB�H�Z�@�"ϔ���7WtP�QL��=	OH!N#\���Ov2�(�ǅ�yͱ���~��u�y���	$� �[�DǍ�V(O4��8�R�i!+\$:!^�8Y6\1�@��6�|{7�g*tK���ш�N=�n�s�,����r)sR D���N�Ü|����CxO4Z2��4O� Z����4��w9�����9�:�L�pG��F��QS���q������	���H�9:���GF.��1�>�+.$�c%�OH���*�(!UFK���#(���s<'}+�R�F	�7������wmww�'��O�#���K8{xg�"_�GY���2bXA<�=��M�E�+�to�a�������b�v�	��}9�2�6b�	�x���8Z<U�&^*�,�#>*�??�;IJ<$o%�$�cG�dG��+�����"�R�&$5 ��g�c��5��u�	x�x!�q�)�e�3��<K~K~w�?��_�$�_���7���7L!_8J�,\.\/<*�j�?�D�E}D�E#DSEkD��"��>bw(i�x�8�x^l'H�@�$�2�V�!I��*�����Q���8J����G#i=���F�Y�(�'�N��I7KI�H_KJ�e"Y/�@��,L6[�D�C��䆬PV!k+w���K���g�7�_�6
�B�pVx*�	�%�U������G�W�L�!$\"z�b��Py��O�ww#�n��������r�`�x�<�R�v&�*ے����Y�Y��˹�i��㊸��ӹ�����'ooo3�!��g���g'�����	У'�
�@��(h.l/����	����:�x"�(�,�r�}�3�GCl)�������a��T�*��1��3�;�I�L������
�Β�K�JwI��<d��w�����ț����C�1�D�a�����\����ercE}ES��B����X�ث��x����$�	;xF0F1�j�9n��.w ���;���W̫Ƿ��O>��_�o �%ԳB�K�>*�=�����v"�H*rm���č%�%lI�$Z�_r^r_Rױ�cG�q�c��S�׎_M��&��R�t�4X�"]!="�#-�j����2�����X|/WV k,*�O�)z ��*&+�*�*���b41��'�k���[�ό������lO�Mv9�>�	������Y�9ù���|��:p\����N���C[7i̷��~���g�PooA�`�`����������V�M(:	�	������	s�&���f��=D����E!�ŢL�&�����Q����|��'���������l�b�G�wǃ��[K��i�U�_N^�e|��l��G6A�F��|�G�'�Ry?y�|6���k02������S�PlVV�Q�V|WX�71�c�.�(q��M|Cx�N�۞��e?bw����9��/d�dВ����͇�#�7������|~~;~W��?��O����+���#S��u�Â󂟂���B[�D�[8P8A8ƺ����@1/�_��4uID�(X4WtHtST$�&2w;��a�.�3$-$\��d�d�d�d�d�d�$�M���O�I+���.�q�3�:nt���x��.������A*�3^:x�����+s��������V�*����ʵ�c�+�Ss��lQWq��C�!��t#41��8ɜ�0
��X	=Ċ����Y�I0$���f���EoD"��x�x��q!���7��$�B�WrLRR��1�1J�%]��{he���,Z�$�){(3�{��|�|�|�s�p������'�i�"X���"J�U�P���ބB,$V�̒OT�MF��h��׆���ʎb�g�c`��M9�8=8��T�Ӛq;p�s@�Y�=�-�Z�:�ؼ��p�b�*�~�E�u^>�	o����H�Z��_�`��8����0Z8��m�ha3��&i �iA+�O I�V���i�9�-�9d�Ύj��R{�FIg�ˑ>� �b�lp�.r�s �����M@�tT,TlT�W|Qt���`�qh�>�� ��gl&H�<�x�N\�3�@�/�������C���L���}�^�P�x+�� ���C���Z
eBWa�p�p�p��'�BcQ+��}D�����@��DoEm�\��C��ģ��G���_�T`!�" �<K����?�4s��q��l�I� �2����.ґ�ip�=���x�t\��M������ʾ��nrgy�<Y�[�V>R���8
�b1�X��C��O � Nڰ��Cى��������r8�9+��g������ø����D�PC�������{?�y��������]G�D ���7]���}�3�A�pa��]�¦п������փt���C�+�gQ]���R��x��8[|M�UBJ�JI�K�$�$�$��"���;~v,s���X��g�pi `d�t��������������c8��˲r�|�|�\%,�Q�RL��|DqYqO�H&���e'�D	ȍF��FH����	�v{{;�[žö�4����p�8Q �q�sn¸�Ӂۓ������p�r�p3���xV<;^O�0���M�)y[y�x�x,�=�F�y�=|�`�`,�*��W���� +8	w��r]XF�v��"��U�.�)�(�!�(�$� �.�]����cAZ<!>c���\b-� #�T�)���,y )�|�0��9u�8�q�iGo:yR����]:������\�Wi3Y����l�l�l"��e�e�d]�<��!r�>�)����m>�@E�b����⍢ѐ�%��r�[��@u�n� �!��x�G�c�3A#��>W9�ǎ��	�d:���
39�8��z܎�\Wn<w&w5�$7���)x^�i�� ����'�F�'���W�w�������gX0uA���������z�p�p3�Z[�n@�]���Q�H-��Y ����>�Q�q�x�����8E�]rDr]�
���Q����8�1��c1���4)�ηJJOH�NJ�����!�8�fk��2�e�d_��y���	�͗˷ʏ���^n��SHC!�8E�b��p�O0n�)MFc�f�ۧ�r���\b��6�ۜ�(�?{{
{.h���{هٗ�/���`�qp�sNg"���k����\)ׇ;�;��$��ܷ �4�ȋ���c�k�-������������ ���>N�-x x)� h��+�=���W�OA�-2������ .KE���˥��@�� �.�懸.H;��~��6�XxZ�Б#�/hS;r���ܱp˔6����������� ��ai��;�w�o���ֲ�0f�dΠG�������_�$�.���Xy�|�|#������
�� �0�ፊǊf�!'뉭���4���cF_�ocv'6�=���T{���]�r�r�s"@8|�2���)מ��M���n� ��ה�����y��%���9X�L���F�.�ƞ�����A#s�\=[�X�%����.�V�Uh-��y��Ds`]<�B�@���P�,F��J���H�����b����ے��=4sl����	F�Y�0��s<���G �q�#���[ ��.�����d�d� �^����m��ݒ����ˇ�g�sI~$̺
+��ɊY�L�F�LQ���7"�����8�����b���с�Ȏf'��	x�c?
5�4�t��y��c����#P4Ph2www�0`4�{�{F�o\^;^�Cx�yѼd�O��]«����mw"�e����W������o�����Ƃ��ƀo;����<p>A0C���-���Ԃ����x�p1��W��N���"�����M���c��Z�N]a<�{�$F�PrPr�SH���(�0��;�t���^ʖ&a�WҼ��1�84ݏ���Nr�ݞ�?�끮�HV0l���pv�ד@O]��(�$�"�:�`��m48����;���1w���\����S�� �������;�т$�ΗVA��W|'(0�a����lc�*x�	��ƿg�8^"�?���˷�٪�7����R��s�����w���ׇ�=��ɒ���s���wp����'@�k*mV��{�i8�3*�5YkyGo"@��W�T,V��1ƅ����4�!p���6��+��C�ù��c��L+������u�-�]��c�S\5P�5��<�c��n	���k�c��xݒg���s�qyb]z����y޼��@^oP�,mV�6�v�t�ͻ����c�s�{���%�߁?�?�����P�W�� ��3�!��&�S����ɘ�̄��g�ٽ�ӡ]�AO(d���1Hc�8�m�B��SҘ�+�6����u������͍��N��΃�.�����{��=ǽ��]�q!�X5.�q<S�3�lu�������aP�� ���D��扼�P�y��t�2��:��6�.�>�!�1^/����]�]��N�@+,��X�{���W�+-є���Y|+�5�8�HA|6�z��O�{���?
�H�a0���h~?�?��<�~:��U�u�M�m�5���y�1����ĿTyp_ ���8j	��_�/	�T���`%��l���C�g�1ȭ$�h}�^0Z,Y!t�I�D�ig	�	�ˠ��ll��Y� �������\�]A��B��V�VP"(�>U.`M�L���%�Zm@���l!_(=�����]8T8L8R8Z,F��'�$LN�}y�0]�L�
��M�m S�f���^^�
�
�@�)}KcF��F�r!Cd*b��E,����0[I�E"��ҥLD�z�����9T4L4R4t�PQ�(ƚI0�O��-��h�J��m0����HK� /�]]���@n*� ﭨ��2��bS1Sl.f����b����b1�+�X&&A?�+(v�v$�I��Pq�Jq�I�D�t�,�)��A�)l�x�x�x���Q�L�$�K�5�����a� n�V\".��ˁ/�J� �$V #�HlA갗8��̗�%2�5z��1P�t#c<�;R2��PI�$Z��s�~��Ȩ��������>�}�����g�3�w�ᄖ�\GED����]Ѓ���#FƇE�D�1u��c����uwp�9nd`DX�Ȁ��Б�q�q��T2:���� PK    �p?��(�w  ,     lib/auto/Math/Cephes/Cephes.exp}Q�N�P��D��EC0�	)h\u�BiI)Ӥ�KhRҦ4n�?��`�W����>��0�9wz�d���Qy���+
�HP�i��
I�_���B=�aj�Ie��]
�EJ��ᙺ�4c��{�.��%�pI.�m�Ss����8�2P����2l+�Q�"\ Γ�F\ Y�ɘ�E�#�'Y�!�n	c�^U�\j��ɪ�Oeu�;2,�s��5�]NK�h6D��d`�3w^}��h�����u8��	c鮼�g��3sY����Ez�?xu���C�xw�}&��U���&x@#Q*|�5<o(7�(8�R[�e(+����X���Y3w����CA���Ө-��� �-~�q�>|��-u�|_鴤�PK    �p?�&�)  �     lib/auto/Math/Cephes/Cephes.libŕAS�@�_0H=��p���x��1t�q��L2�+-���<��5�������C����/�lXj���q3o�y�߼�߾M�~�����:^����tm3g��5��!緎�  �)�x`�H�<�/]#�P�Tm���[-T�*�mv[�>R>������x����r����<h�v	9q�)�-�)���Cz�е�8"H� il�s�N \� B�^<�E�uD!4����4:���X�Y#`a	�?�*�	��������P��ŦH$&T�{p{ђi4Oξ���<ZG���9�n��5����~���N��u[L�����y�S�,�<}N�6m�2<�hC�u�]�9}��@]��S�B����L�b��`��Q�B�9��\�j�C�m�H�-y�N���$j�罫^c�<nY�f)�:7�`���d�s�wDz��ɂ�'��sy��|n�\<�iϳ����
%=gdj��Q���C�|25���)߄Pc���n���,D�`�dyhdՀ(А��R�P"������xiw��xS��PK    �{?`I�|   �   .   lib/auto/Statistics/Distributions/autosplit.ixU�=�0D����H�v��ܩХs�,����_X
����Tzp�p�7N�xj����({����ݩ����J	�3_�0�;�t���J;�<�v �\�v[�O��	�MӴ��U �#�b,w3,3|PK    �{?��4:�  �
     lib/prefork.pm�VmS�F�,����m�����&$�L �a��zC:�h\��w���b��zF���>���s�Dġ�$��8}p��e'l��f̷#�nk�_m;�8���G�1���H�<`ik�nO���Lz�g)�����V�&,`�Y�V��K3x\,;_��W��1t>\\~����_��χW����z�����~?<�ai[��18}w���ެ6\�9�LD�I�[���&r.20I�d�.���֦"�A��Z�@�ߏ9�9�S2����!��o[�c���(�b*&L�8�Fp�H2�2��6۲�����p�i�,��$N
r1����Q����xZ`N�Lۋ(�
%$%D����b�s��jG�?�@G­Wqȥ)�9G;�S�9gO��ʶ��l,:��J��(�ǰ�W���xm�r����e�e[�`�q��Z�	��J"&!�܇\U�J�Y�ak�ꃘBg8��Ė�}^�cЕmSmE�ĸ/!@a3��}��"��z ���#"�ӃЏ�x%Y�aO�փ������vz���^F>���T�b"\�iD����L|>E�>a۽E-��B����B�,z�$��C�������<ǜ��)D,�� s�U��v��~���{�x�=�������z�������-�8q4e�z�����B��#Q�g�$@��T�v���{���e�n��Y�r��I�C���#5}4,U4��ڊ�Υ��*	Ǩ\�F��9�}*�$5Ѩ���e�8��7죲nF�ĕE�7�rx�٢�jh�\S�
��rH�a�!*���`�;��%�\�u��d��(~�҈PՔN�a!�@��(����A�n��Mc�%�$4u}t��%�!�B<�M�� t3��{�EVk�ʺɒ[���`�	��G%2M��/H�d ��8Gy�^Y�)��B�R9��I#�Z���T����t-M̓�~��Or<r�U9����)���PUPi>��l.��<�L=���@�i�go_�G+E�4g��0�8"O�U|T���f�h��!܌)��"ဟ��癅n�� ����HߪPᘌ�t������*�¾�
>�[���!�!�%�)��ٹ����7
S�2S��q�zAt��o�-��"Ee_>�iڨ�PSms׃�F��j5(Xu�ĕ�B������KI�m%9�!L�����ѯ���6��E ����}'C�x����lT����e�Ѵ�7x����C�g��D;@�,����tR��4�����ہ�PK    �{?��1  �     script/main.pl}�]k�0���+RPa���YV��Ơsb�.� ����1�_�c�{/ON�������X�,I?�,�i�e4O��d�'`sbZ����w��*���Ff쿓0e�0%Bh��i�QF42�"�
uU4�r�/�,&*����������o��	f�!��b�b���O+��_��-�^!ּG��O���ēG���:��GX�����U�O�`y�����s[��2���Ә�9e���C����a�$�4
�p8x5ҾF�b�5�#J���?H'�����%��x�����F_��|�n3�����f��v���X�PK    �{?���{7-  ��     script/miRNA_1c_ana_v0.3.pl�}�sG������!�@ I�&E���]V��P�})�F�!8"0�H�2���TI�RN�ז�:�ٳ��z�k���w�i�n�+�w����ګMRy�u�L�L R�׺;�- 3�_w�~�����uO���t�q�{��aS;�cL��]y��<�:����f�r���W�u � O��tju���������,ܴ wnN��V�jz���ߦ�Y�o݈�Jj����{����|;�w� >���n�Eիg���+�gΝ9��<�����նV�Z��N3��?iN���GO9�m�����ݙ�և����=u��r�/�AX���b8����SSS���.����v��m����Y��l��;��B�?`���ێ1,?}�V���~�=��5�D�ٶ�M7�8u������f��+�m�ڴ]v��B���<sf��N�<�[=�|��ix��t��T��R��96?�$�xN­�yfE~b�6��f�gk7>�l������w���|�vmg����݁�{k��a�X�n9�;��.�����ղ�%�Y�c�ϟ�z7�� �-����2����r|��,�[��v���\F^��t��9*���җ�-�Xn���ݮ�����1ܖc�\����`v�����X��؉�e�$�>`SK�e�s�݆��C�����ul�Z];;��uZ�_w\`�.QO����>`�7<o>�M��CC��·�V�J�:�k�ˮ���푠��:���X:���z�{K�*?܆��^>�����R�-!��}fH NxB?� .>�m�?�m�F�ɑ�%x+W��z���:����۷�б:�I��A�ٲ�O�@����;n�r��:���:1�rf�m�7X�1��.�@J��~������'�^~����ڝ����?�9~����K�KQA�����n��1�l��;^���~�����������&+�"/Ø��
Ӆ������OG  =��fy�V#���ݸ<�B��N�k�gk嫽v�)ś0�
��%m"�Qj!���'Y�� ������0�F+@-�p�,b�荨�셧N�WΟ��zn�"��\{ͽ�V�]�S��w�y,/ъ«0!@`1$"� ����2�)��v3�|��z1j�~��(v%[DS�S�&GZ�3�c�ant׆_8�� u٥�q�I�Iލ ��ѣ�+J�����/Xd/���$ 5�پ����P��;�X8x��!�����2��A���_k!�w���ԃ0Wf���,�~.�B.?=�N̦b�	v��5����~�e��;����a���`��\�At^ɻ�zs�4R@n�л%�]A4��^ߪѷZ�m&��(�T:�*=�]a��(�?�]b��/ <J�%�=���O(��ty.G̡L���� ��G���|I��s�G��O@s�	U16�տ�賏~��7��`�O_�ux	�~F�?� `#Vw�J'�j"�&��]�Wr�6T���)<!:��9��4��ޏ~x��]�b6�]/�C����k�^�`�7A8�PYiznh9n@��v���A�����Mh�D�1!yQ�u�5�C�r:2��ކ���O�o�C ��,?������EIj�t~�4@s�}�4BcI�KB�w�۴����ε� ,�F?d��l���m4@�x,Z�Z������D��'�� ����:	���*p�`�h}b�h����-Q	�M\��/rQ�j�ߢI�Zr���*��J�:TY��`�'�0G1��%�ժ�x�=/�ҥs��P鴂�Y�M8�_zj	L�r���3���kRC��y�P��4�u��
�c��8S�;��+^���v����Ԯ���V)��\��o�B�ycô^�ίTq͐S�my�C'�أ��D�q@k̙�:܀�5�km�T���:��Ǫz]+���;��yI�
:�NWg�tZvWt����|�ɘ�i�xh����EX��X/E��%qIH�IO1D�Z�����
}Б�Wf����ej��F\Du%�_��Yhǚ(��6�V��������&>_հm�qO� ��OHU��}ͽdm��~<C�.�E_'	�-��J�5a9�������P�L�5����c��.�r(ed6L�m�UN����y�N�L����Z9}�v��͕�B���� ��P��+o�/�0e��Y>�l�~�O�߼�,�&�L:#��df�S]�_������t4؂�q�� ����X���9����>�;*�T�[���-I
�sW�x�:jӻ�z�:�P����L����j�n1Go/�[���Տ���Q�g\t�1XW-tݜ�vF7q�ah�Z$T��I.�t<?D{�b��`��V���QC*����DL����'��D����Fua��P͌���:	�-'����}�q�R�q�����aE�^N�UI���S�.;�pZ%vā�e��"�����L�N�FE�\J6D�vE�a^z�Mw��x5�=���?�P���E���&�>�����J5jMbC3S�!6e\s9*.��$���AD�K]��y�[�qq�4�끫,�*�i�C�%G�u�_G� �:�D���i~�? �>8��G��x0�.
L ���N�I�����X]K,hZ�e�G1[<�}��hȦ����Ŏm�3-�������jn�^���*E�-eg�<>����su`��у5?>�n�}���~��+����ﾳ��w��7_��G�����X��'��@�	����)��$v����|�R�fa�Y]�
�Sg�^q�)����a]k�=���5w|샯���O������ۿ�{i�����_�����n�zi|l�;L�X�wl�e|ߤ�p�j�4=�r��
A��E^�f�ߊ�7X�F�N���}�C�\;4g7k� �������ǟ�������|�����?���>z��7o����������/�z��{�?��������7��|������W�}����������+������{a^�����;��֟�Є0��j�>j�c�@Et��^�Z_j��LA|)�EN|�!�� ErѓB�@,����n�io:�_D6���RHq��Z�?�W���d��LN���v��n
�r��/� �Mq��r��gw�nj���^��m��Ħ2⁑���b��7�˰��|��:a���<x���[�K�q����h8�`LQ��;�J��&/�va����Z�ׂ����?�V�-3c��B	�}UY7a�	 _[��4�ef�2 ??J�(�_�	�sK[�yǀ�P@�rEш���L���u�Z���"�P�!`�y*iY��aY���Vڃ�qh߂�+@�u���x�P��nM ,��Ad��&�d7¨n��2S��nT�Z�	s�W�֨5B�[ڹ��9}_˰�">`�'���vGǓ­�%��j�œpO�����8�iv����f3/�}�b�� �_q`MyxQእ$���3�����7a�Fa����2*�K�2;�i7���﫲�!�u����҆p�����)G�Q%?
]��@��s��_Ecʶ܊����-~���z�6�Y��4ah!���m��-�W�ɇo����*�o|�zS	�X·�R}[8�nr��A棓��74L��p��w^��U��*"���f�.�ё閷�Z�J�*���P]�1�G#�����]������z��V��jvo���{)��8r ���U���B�-F�$> ���� �j�85xӑ�e5�I�ѩJ#ݔݍ�=&��#h
�m¢҈$,_�/���W��Z����dY������ʟ&x���k*Z��%���SKO@� �/�59�j�*�cy����,��6X*-�|�R�����b������%�_�d	�ERz8�������G��i�@o[㏪���l�*��E��8裌�ƛ�&J�reΰ��/��3�+o��#]cG��ȈI��4d�{#X�E&Ѯ��ʸ�(�p݄�*j�*��WGh���A�]�x��Xr[��y��dQ:ͅ�)�-��V�0抣�������ʎ��2����R�v�E���uަ�6�ۄQL�[��[o�����w����O�ǽ�������^����E���B磝_�9P���o�;q]
u.� %'�'v�*�	EX����hG]�����ᛓ�|r7n��j�4�`�����G]-��-2�9�q�q�bA+sS�A'��_ 	].�x�H�뮩a��ќv�=D�ň��j��.����K�|�T�Mo{RJ��B��*�0���m��I�)5�m�Q�-d�c]qרs�EJ|Qt��`Ƥ�i<2��Z,M�h5J�z��ҭL���p��|�V��X��<Z��9��f�̶)F@%z�H}�s���e�E�s�q1��J����Ѫ�Z9Ft[a@���L���"!0��ɥ"�]������	TG]�k�
�S�DC$�崤�r�A��8�*�����@&��KA�������E��<��L�~��{N�4�A�8B7B|�(�FU���@���XQꙂB�N[���D�Ś;Z1-B*��C��3X�
u�
��l�)n#�A�U�?@�Z�Y�k�N��>���/o��`ti#j R�A3$`�bT���X�pݴ�:�.�8 ��27���.BϷOq�R� ��?��\��C�5�H�P��b
E����������ZT�9;��Z�u��BJZ�u׸2����و�+��8���S�)�J��76�����fm[��kmL��0;u�ZfZ�a�)"��I!MD[��E���p�����۵2;���@i��#�ٱ�~l��� ���s�sc�L+�oj^�w7aևV,t��;sze�<O�ÓBJ��\�=j���Ǿ��B2KtM.ѵR�Dl���o9nX�<�o��V}U*�Ӝ���6���y�-qa����yC>�����_��O�$2���wt�r\P�!�e�%�4�"@�s�k¨Z�*!��G�˒�Ô�r��D��I3:���}ET%�ߨT*�G������r��ϔ��ͬ����\	��57�4M޺�����ӷ��?~~�[�ڙ6.����%7�t�=`�~=��&�x���H{���'�,R�UD�Ü��ym����N�L� �B�O��	�2��������"~�sE�$B�Bh�Q,!�a4a�2�V�����%�eȜR�8�.5�ո�/J!1$f�B)�J�Z�rA b�b@a*��C��)�P)���C�#V�J��»ǕMn�a�}JAB_쒆H���깬��Ha+���hUh<]��lIy[�t�J�i�yŕjҒ��!ʊ���QT�/�-�$T`+��>��� ��M�����X|7��j���oT6k�g��W��
�����}7X�\G q�I�{�d��IvIp�l?�;]ʞ�C��`�� ���<_��ső�\����E�on���S�~ �t�O��v�dN:�y� M�sV�\�%׈�(�6�� sھՅ�z;�`#g���B��F�
r���m:��qB�� H ��"��5��L���Je�oS6֕� �<�YH��N�z`��P�m0y��)�k�1s:��{[RY|�V�H{�&ς�X��@�#�J�P�%��z��7�] ��uC��6� &Ǐ�a��f؇K�sbg9_v^4>�'㼊�ýtlL-X��
2?>vƁ��s'K�R��t��]�\b'}�����`��6�r�,��-�����:-߷]�kO=�)fjshB���а&;o��ܴZ�*8��Kˬ��O,�'��Yu��c3S����W�cCW�CV�#b>-D�����Fqy�qLZ�XK���|ғ,��!O'k�R8K��)0sK$�N���S�-�R�s����&� 2�r-ğt.W	_�K�:x�����&�bUL�%,j�l��9�a�ȕSLe�K�X`Ôm�LG�*��`��C>̺5+������苰�$���i��0�f�%�\�PF�~،��w0�L�k��0��M��oGӫ���sHP
���F"[���bc�U�����x�)?�L&T!�͵*-�����(":c,��(�SCjT��8�p=x�J�:���X��x�����B�P-�L1��&pL��׮x{�mӾ^�⊼�N��l�`VQq-N�t����� � �r�͕�:�hr'y_5N`�Y��l�A[�nz�7��]-��V ,��A�7��I�ǖ[9}z_\��w�~E�/��Bu���=0�s���1�w
Ov,���-���U�Fh�
� �jo\��^��kH�$]�5�N�eb��A�
i��Y��ѱ�[�o�|-{��ml�����,��Bn�ON]65�m��}Zl�X�ű{�iu���H^D+�z⡲�n�K�=��6����^�D�-P�P1@ם+�v�ς��'!?W���-���=�H�_��m#~��m^	|�-C+���(���wgJ|%rg�L;��[`��.���i�X�R��\S.\���=�u���ө�n��F���m��N��H��or�:���c~JF�������:�rj���N0��ט�I�ǧh�s<�z��;�޸���^����֟0��ZDh�|^�~݈��Y�N�����$�)΋�VpW�J�������Z����c�i����(n�gU��D��`�� D1鶄3�ո�r0=d,;��
��'n&CEv� L;v�w�s�L���ڧo��拯�x��˯��)������>��<IV��C�E�N"[�_����� v�0*}O(s� ���b�\�F"�ړM�i��=-�_�
(gP�tI>�I=�M<!%�ĻK(M�Pؤ��HF����4;���)v(P���t����Z\K$�DM�^l��쥳���t�A4N�щ�Zls���%�����B��$栏k!���A@��/���Ru��*�^V�,q�;�$*��7��GW�Ao��^n_�/
��U�!��k��'xJ��:C����W��U�~��n�2};H���@raD�u-�K�+�R�@5
�S�4���f�E������"	���!s=�n�������b�p%�������8���a?y?�!�����48�9-��k���314�=%s�owɮ|��ۿ��KvF�I
{(��/2���G}`_��Zy3��%��S\]Jssz�6��K��`��޿�B�]�
��C��)�D�����%w��΍LކΠ:�tr�{Wp��Y��G)\�Y��`���_���Wo�F��t�KL��2�����Tߍܠ �r�;��5d,A�<�������?�-���<q���Zu���qQ}&G�:md��ѵ�� )0�O��!g3�t#UIMD���Q��r�vJ�֔�9 �T�4V"㭊�^ F���^~ȼ�b|L1���3���g�C���"mgG�� T�>�74Ђu�%#g)�JC"c����j��^�`q�z��\���fEG�!�XA�G����G�������tԠ@c�][�)����(Η�Aq;1�A�7A�1�p:�7A�`A#��h
4ܴBf��6��E�p2�D�R,��B��X�F�r3�D0`�@I�%�E>�i7�����������;8hp��=�a����	�>5d��R�w_d��3�LgKgǪdQq�ir`Ok�)�5lB�3���)����{D��⌘:}{�Q�kOF��(a��m�����p�R�S���\�	�H*��`�f>0�TL���4�ljc4ќ��Do�i*���ݞs�A3A�1�}����o�c�1�~˞3ͷ1q7����Ӡ�=�I���:��b��OQN>�K��~�ʾ��J�'����o]߯
>�)��� ��^s�������M�盛�ݲY�?BKJ`K1��#�-�-���P�e����H&eǜjǨ��}�O_�FR��q#Y5�}`�ܗm3ږ�Q���(�cT�f�q��à�(���G�b0"xP��cC�Q�Ź�0F�GK5 ��y�x�@L�P9����20o������Sl�Qe
d)��B�@%��p&1�)$.�ĸ�b�Y�><� �>eǥe�i`�n:F#�vH��nt��)~�1]R[��,�s|N`�R�zr�(�]@	4mR
�5?,tl�n6:S�T�ǯ�3��0^:gj�"z�U*�1��~�}kbi�/t7x
���qR�Y7�AE�x�O	1v)�0XLt�CV����H�)�Y��o�<�5)����ΣH�M&,y����0܂)F��F
_�V֟+��b�ڳ�95x�rʔ��H�"���Fa�>�{bs�Ɨv�.�ijN�0���F��24ֺn�G�j�E@Q�	�CHBqR��8 aG'��fe���VqN(F��񷵘�Z Ek�3�nAf��-a��
�V4DB����#8�e�m�(��e�[����eg�%�~�X�h16f$�
��Tq:�8� ��Q|�b�;`�Q-�EJ���L 0�7�z�K���N�G�2��������T������e�I�O���j�n��~917�4��d<h����c�QÔ�?@�������]��:!޶���<pO��B;�����Φ�Z[���@0p
2�E24�r�H9jSQ��x�A��C�hڶ�������A%ְ�*��IX�a����i�m���ȸw?=ϥE�S�2 ,���.�m�s#N���|�y����F�pf�evI���� J�Ga�U��S�>���DU� �(��H�7C�C����э~H~	����������@���Г����1]�MnД�`B0%q��"�\�d��j�y�خ�!�rI�����ꪚƚP֔`Z�ђ���"%P�mԜ�9�QL��ݦ�;-�P�lш(�t���;��0����E�{�G��S�6M�jE���`L)�R�Խ�m��ĺXZa���TD~%�O3�XM�=������R�@�	�ʯ^��޿�P��?���'���?�8[<����K�,�J��`n��])9Z��";Q�\ /�:�[�� �ZKǣV5v�Q����dMDY��`����Ҥ�$��^ĸeP�¹UJ$.�m�	���ɿ�uzX�d}�k �|=��w?c7�?ɱ�����͕.&�ݥ�lZ��zh�3̇Q���*<z��B��ɼ��!�5���6�A$�E�ߠy4 *j�0��`�rC0	������%���-V��a9�"t�I��[��zV�_�tO�ߗ�G��-y��*���	���w�~��8��|��;� ~�M\��I:��V~������>�E6Y��� �Ѷ1ҙ{��p��҈8nĻLJ�F|���9>Wc�ĝCbT���K���Z���t�cJ�Jj��*��ۨZ�)]�::��̱�\��j�j�7�jcV~������L��J&2��i]4��d��+���ϣ÷
8�E��$C���c���@'��\]O2E���5�fgjfФ��D�L��blə��	n���g���S9�����Z���9����O��4��`SS�m�CR��Btna�aC�����%��R��W��JT���B�0z;9Ic~���.��vo�&��8��k�j�#�>��&��e6�@������|[��$u˺�#C�/��m�����w�ׂS����'�qr����7�jx�G���;o��_��2���ϔR�W��O~���~�������/�l��ET��A�q�~��(y������LC�jG���������~soo����}��T��H=�ǖ�ͳT+td�T����z�tdBtwLEo��b�$2��9��И�������=_~��7>���~���O�8L��b6��ap��c�u�e�4Kq�,3�*'.�J�G.?��G�gB�kɎ�<k��A5?m���C�l~�?�R���߃��ڱ���nj{�Q�� $u����+�����%Tk%��1h�m]�S��,R���'R�����-0e|l�Д��s����K��[�����J�1���j�(��"�P�(��F�(����P 
E������'K��+�J�T�T���Gu��b���\��4����r�$b:1:��6�N:���^gq�7�o>$c��6�Wr��^W���=�P䚄"�$/n�G�.I]9)}�O��C%�#\`�'�ON�X�	��./���aP�l�}d�h�M��i5B��쭚�c*�6�"�h۴��5Iy�&���<;��r5�Q��oB5KG�ld�U���]r��8���Itk�()�Hr�J�Ew�%FR$e��g0��0�t��;�	��-{��vL���L�����ij��fic#��G�tՙ���q��1��-�Fj��U�:agg�A�yB�It�Bg%��Hܬ�@I^{B��� Ç�z$�1LGE+@�v�����{bh��4�oifF�;c:�����I�j���Hh��:W�c	��%J����
�"պ�<�s�T��0=(�g]\�x@|E��/�"��[��ˉ�0�&~2L羂�8Z<���:���Z�8��GS���3ˊ�2�����+�fy��/d�������M��߱�;�nDDT��EÎꂹDu]�q��fF�ZV�c_������J/Ʌ��57x�S�2�o��⑺���~�[��7M��6\w)&Ks���}:�����S\ݕ;�i�&�ʌ�|���8���lr?OnmM:���h�%����Wep�A�%vTULۜ�? �CO�L9�����Y�jzh���*�kMe�O4���|���5��bH;�:��G���;cTy��
�G��v=���7��!��i�2�=#}2�����I\�O��]��m�*/Fv�@�'�3\K(�Re�a��t$j�i�����T�a�ω�ŅU�j<{%�D9[?)�&S��幕�xs�_����Q��hͩ�9��'�F��£:��Hk����)W���t�CNmk�h�o5܂5V&A��J��T��6
.�����N��A3��L�N�w�d�GX��4���Ic�E�AޭxJ̣��cF�@j:i�`_GD	]5:&I]e2`��D��a�\���]���并�
���~�ֶ�J��w�涖�""1Q�?��$���m�TQ�)T�� 5cTIZ��+gc��A��dא�@��ο�/�����V�=��L�(�|G~t�!�'��{�Uo+ƻ��X�n2(�:�Ԍ��:�P|��$��ur˘'�J�]�`\����)o�A��k9)�ٰUX���b��m�hV�Ƴ%.K�ϸ��gpVƳ%e�RH�����:97pq�@�)�4Q�>�~xӾ�mBd,	K�3v<��Ͽ�Y��y�:��^�������V�o��:����x�Gn"Ǯc:r��iĀQ,j�42,��lx~5Ⱥ��(z�V�n>��%J<�\��t�©��PK     �{?                      �A�[  lib/PK     �{?                      �A�[  script/PK    �{?���[�  �             ��	\  MANIFESTPK    �{?�I[�   �              �� _  META.ymlPK    �{?l�7�-	  �)             ���_  lib/Algorithm/Combinatorics.pmPK    �{?�ik�  E             ��6i  lib/Excel/Writer/XLSX.pmPK    �{?{�]�V)  �            ���j  lib/Excel/Writer/XLSX/Chart.pmPK    �{?8��d@  (  #           ����  lib/Excel/Writer/XLSX/Chartsheet.pmPK    �{?=GG��  �P              ���  lib/Excel/Writer/XLSX/Drawing.pmPK    �{?f��Fy  ^B             ���  lib/Excel/Writer/XLSX/Format.pmPK    �{?_�f"�  �!  $           ��·  lib/Excel/Writer/XLSX/Package/App.pmPK    �{?5\�h_  o   -           ��Ͼ  lib/Excel/Writer/XLSX/Package/ContentTypes.pmPK    �{?�:��    %           ��y�  lib/Excel/Writer/XLSX/Package/Core.pmPK    �{?����
  �F  )           ����  lib/Excel/Writer/XLSX/Package/Packager.pmPK    �{?6�BT!  �  .           ����  lib/Excel/Writer/XLSX/Package/Relationships.pmPK    �{?)���    .           ��5�  lib/Excel/Writer/XLSX/Package/SharedStrings.pmPK    �{?%QL�  �R  '           ���  lib/Excel/Writer/XLSX/Package/Styles.pmPK    �{?�<N�	  &  &           ��J�  lib/Excel/Writer/XLSX/Package/Theme.pmPK    �{?��  �	  *           ����  lib/Excel/Writer/XLSX/Package/XMLwriter.pmPK    �{?���wn  �  0           ����  lib/Excel/Writer/XLSX/Package/XMLwriterSimple.pmPK    �{?����%
  �&              ��V lib/Excel/Writer/XLSX/Utility.pmPK    �{?�a~�I/  ��  !           ��� lib/Excel/Writer/XLSX/Workbook.pmPK    �{?���\  �k "           ��A; lib/Excel/Writer/XLSX/Worksheet.pmPK    �{?l��%c  �*             ���� lib/Math/Cephes.pmPK    �{?!D  _             ��/� lib/Math/Cephes/Matrix.pmPK    �{?�a�x�  �f             ���� lib/Number/Format.pmPK    �{?ү�6h"  �w             ��t� lib/PAR/Dist.pmPK    �{?�wR|�*  �             ��	 lib/Statistics/ANOVA.pmPK    �{?�~z�  �             ���5 lib/Statistics/Basic.pmPK    �{?pd�    &           ���: lib/Statistics/Basic/ComputedVector.pmPK    �{?�E�  �  #           ��? lib/Statistics/Basic/Correlation.pmPK    �{?��9  b
  "           ���A lib/Statistics/Basic/Covariance.pmPK    �{?�wn��  �  &           ��IE lib/Statistics/Basic/LeastSquareFit.pmPK    �{?�4,`�  =             ��SI lib/Statistics/Basic/Mean.pmPK    �{?����&  �             ���K lib/Statistics/Basic/Median.pmPK    �{?�)=AJ  i             ���M lib/Statistics/Basic/Mode.pmPK    �{?�(��               ��fQ lib/Statistics/Basic/StdDev.pmPK    �{? ��8  �              ��sS lib/Statistics/Basic/Variance.pmPK    �{?1CX�[  �             ���U lib/Statistics/Basic/Vector.pmPK    �{?/���  *  &           ���] lib/Statistics/Basic/_OneVectorBase.pmPK    �{?��E3�  �  &           ��u` lib/Statistics/Basic/_TwoVectorBase.pmPK    �{?��'B�  f              ��Vd lib/Statistics/DependantTTest.pmPK    �{?H��{  	C             ��$g lib/Statistics/Descriptive.pmPK    �{?����  �$             ���z lib/Statistics/Distributions.pmPK    �{?�Я��               ��� lib/Statistics/Lite.pmPK    �{?�����  �  !           ��� lib/Statistics/PointEstimation.pmPK    �{?}�NC	  "             ��Ց lib/Statistics/TTest.pmPK    �{?�e�  �             ��M� lib/Test/Pod.pmPK     �p?            1          ��K� lib/auto/Algorithm/Combinatorics/Combinatorics.bsPK    �p?���-  �p  2           ���� lib/auto/Algorithm/Combinatorics/Combinatorics.dllPK    �p?�FC|�  �  2           ��� lib/auto/Algorithm/Combinatorics/Combinatorics.expPK    �p?�'�A  t	  2           ��� lib/auto/Algorithm/Combinatorics/Combinatorics.libPK     �p?                      ��{� lib/auto/Math/Cephes/Cephes.bsPK    �p?0����W m             ���� lib/auto/Math/Cephes/Cephes.dllPK    �p?��(�w  ,             ��� lib/auto/Math/Cephes/Cephes.expPK    �p?�&�)  �             ��� lib/auto/Math/Cephes/Cephes.libPK    �{?`I�|   �   .           ��� lib/auto/Statistics/Distributions/autosplit.ixPK    �{?��4:�  �
             ��� lib/prefork.pmPK    �{?��1  �             ���! script/main.plPK    �{?���{7-  ��             ��1# script/miRNA_1c_ana_v0.3.plPK    < < 	  �P   d8c0920588809712e6eb3510e66b121426945f1b CACHE ,
PAR.pm
