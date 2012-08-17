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
�[Sn�
L��LR��������;.��zL΀���G�#��5����],�`'Z�^&�6B��~O2�|[0��HpzH�<��:�05c���ط���_�rs������a����f0��v�e�h� �a�E V]�J�
�rS�4g�ϴ72�������36"w֛W�|�&���-�78Rk���ة��7K
���_�=JR���k�<���p}�&��
	S]�Ff��4����2��\{JE��	Ⴌ/�$J��bs��4M`�8E���Z�P/��r�<s+��ݼ��s9K�\[aiŃD��0W�l��_Yɳ�hc�z�Yͥ/X�X��ZKA��2��)��C��UZW��̦t	�1�[����|�^(�6p���b��6��&X��NL��T\	δ���<3CK�1�NC@�tU�Ōgy]_�Wݞ��tO���@�����/��$��	��{4�JO%k6]#V�����t}|!�R)1�2�r�c}?#�s�EB�U57)��vg������j[1_S��悮~̀�\q#К�5p�*��F��1�j�Tw��l��P%8�B&M"{*�T�qF�$r)�֎6 �(?5-Y�X�jI��l&#Ԏ\2P��+1Y{�� l�R��7��!Q(N�D"���TG�L�3cx��=m������(��nTy�
�ӆ���zƝv��:����Dg����(�N�*�nV:��q^�����B�}����V�PK    �{?�ik�  E     lib/Excel/Writer/XLSX.pm�SQO�0~߯�	���0����4��$��R�
	D��_h���>it{�[�֘�+X7���F[k�/}��b7���n��錢�/PK    �{?{�]�V)  �    lib/Excel/Writer/XLSX/Chart.pm�=kw����+�	�FJ��T�\�~���y;i{o��,I��h���.-1���/f�] \�"e7QNi1��0|��9g��Ӌ���Q�5/�����?��&e�7�޾5KFgɄ3�9:"��#�::B���n}|�?��?q�]�������IQ�s�z�O����n���4g�"�y�����yZ��(ߣ�٢L'�5;���������?�iξ}�L�2�a?OG9��p4K򽢜`�'�h>�y�`3ɉ�����>D� ��2���H�O��?ˊs���A���N���!۝��}��Yr�ּ���^�@PԿ�Uu��j��<)s����'�~�γ��&u�{[��7�ϱ$�c�fi�`��o]d�
��Oӊ�<)�)�GQ�
�`j��3���$
ؖQ�2�A�D����6�j��8WAl.��G{n`����B��$e�,�����a���,�LL�����%nPP��\j}^�
V�b����T�����bݝ[�%��!��������x�J�qgc辅�YQ�U°�q3D;0�` ��e�t�g���O?����M��u�ӿ>z��G���:�A��լ��� �KgtC��km���E궁0k�d
1�,��w�xP*��*Fia�x�$��P�]�R����=��+�R
��DZ��$w{y��"���	����� �R�`���J7�|.�+%�d>�R=�QW@�E`=3�-���E풆��՞�۳�lX6ڏ�������g��������W���{5�~5�����?o����&�W�϶��|g���9G�<�� �E�u�`�|�ۄd�cŜNr���'B+������[M��pZ��'�j��|�An�
*��1&�G�`��=5��!Հ�-�B��$E�9�8��d�PDu�R�>�.�|��Y1D��3}��-��\#at�	Ŕ��蝉y��)��8�)�9�0�!׍��pAV	��T���+sYf�o�����s:m�7��xK�;��W�65'�`��0���KfU����j9$&�B��	n��{tC���Y���a�����Gkɔ.�x��a�v����J֫8�V1��|�k~J �����oE3�ܴ����5y�A�U���!�7�+��F���q�g�]@�iE�4@wlŋȗ�}L#O�
�˳��}y��a�'��8�� X�7ӧ��߷[�1nO���%8	Ms4TZ�{����'A���^P���PgKE���\����o"�n��7F�^p
����~�~�GƱ��ؐ����E[�y
x���7y���,y5+�q�"�Ax�y���r��N#�(� ��3)������n�7>�_*'"�Ϝ���	�=h�M�a���~�*<4�w[����{�»���Vᗦ��V���V�W��WY:�Y�V?{c�/��vaQ��F?�殆p��	���\�Zh�95˳݉�A{�~��|�Χ���P/��{]�0a���UΫ���$|��#��	��}դ�z�����O~y$�y��Õw���Zf�:���>��ޚ�Bv��ڝ�;��ܘ �IZҕ�F#�\,���^�)��V#��t�{�F�r+��[s4� �	���Y��
L=���o��ܷv�U{�;����[��e{��j�����͕>�4����7�a��Өzz�~T �ۂ:Q�D��uI�֎^��V�Լ-�J�;�+k�F[˵��ݹ�V�:*�~_�b_+��wD#Ln�G]�ͭ�<�J���vk$+	�X*���M�"j���m�A����M�n��i��4�
�M��?-��L�|�q	��� .����:��J��π�����w�jhZF�c�,��)��(3,�?��Y6�nf��O�4%�Q��g@���,�*8��m^~���S+���-���_lAiksݘ�l���ͅT�V[[�v:�v%+!����-��,�{o�4��W�`'Ш����"iJ
Z]p̲��ݸM&�/�>���ѩB�7�=���~LO| &�3f����\�&���r�3m�{M �����	d���;�:U�w�}�&y�u�Z}U��,ك/����>��|d��ő=���m�F��ك/���W}������Ȯͬ��P"��NMХO̜��Rp�4|
�G?�Z誡L�l�Q����+�Ę& �x{�dy�W
ӧ/]�S H<���ex0�rO���0�Og�B1H�4����� �,��W��37V�wT�	}R@8'��Ot"y��ؾ���p��I�d�r�o�F�EW�86����)�J2��z4��k筷��D{�};.|�o�!�5��,t��f;U��0�3�m7v=��S��em���T�hn�9����#H{y@�(a���J]{�A��� ��=��˳�R*�K9(`����C���Š��+�d^W~7�W�D_h�\�����A��F�$��_��˪^bFI��"�A>s����nr��n������P��8|��H�H�
��Mn�`T֩������ĵ�7�.%?��<�YWv$9�i�Ȧ�z��[�vגM�%�����sh"�%���,�X\2��g��DB���eN�ټ�9�[w�����"�#����ˊkJ��b+.V���z�$��#��x*V�E�xB��%��fDy��cMG"W���S�01��.L�� �k=q-C�)�"�)+�O�I�.�kN��Y��9�
\J�#WO �|��gmֺ��Oac8��P��&�
����>�K���QpJU�x�M=즋 ?�	ʔ�̃p��X��*���
��rORy#��\Y��vn�|��s�L��7��}Y|�c��o4|H��@��ܛ&@��Shݳ���53/
:'����Z����s�Pܨ�	��fbk��Gw;>���L��]��6��h|{����-p�/'|��r���tv۾�i�<��ȵ\�X7���]���#����0��v�K\��?�[9۝ٸ��٠<�K�j��Lu��ٲ�g��9"x8M�p`�Ai�d�[S��܋��6�慗O?���K�q���ŋG�+tV5�-J��$~l�ή4mz��B�]�7^�V]�o��Ox� ��Q%e4�G(��0��~��~W��1��~�hX�u1����+V�<��j/>��,��;�طw����b�*E��۝��`�#�.٪7�i��A��2��a�����MxUJױՔ�����4��FF� �`�� ��\c�ё��n1�Щ���.{���mB�60�������]h:o�~H�2�w	E۠R��t�a���=4���h�>�0�k>1Q�sZBE������ѽ����i�o���皔�4��&�c�E�ƙo�@:}�D�U��R��y�ܝv�!mqʓ1,5�:�Ҋ��� C)W�	�&)'i�E �a\�n�OP�q���^�h��-6�C� y�}��M��u��3��g���K�#z��P{_�3�3�u���Z�Q����������t�cؓȅVZ���=�������^[�k�;IZ�~�
O��^����5ZW��<�����a�w�>��
[QY��l(5����ʥ�_���}�q,?��wR�������&?T��n�y����8�W�Z�	Y.���`�?�L��{�ɠ^��،p��%L��ҷx�.)��*��Mȯ'�Z|�U���+ʯ�ZW4
�u�<�}��'&��������nSؤ~p�Mx�F�F��|n�{�J·(�!���A����w���fn��J�N�,�P�g��CM�:u�����-��tXD�#�-�Hnz��Jmr
�[(���v[��+B���G1��Ŏ���q�$��6!��s��H��x?s7&��>h��xE)�ZҢA��"d���Xq����� ��h0���H'�8�%�\'�mn�]H��6x�,�e`�+?Y��eݱ���G*��3�K��c�$�2�>]#
��p��^{"�=�Cך�A^�4����d~�-�F��Nx�C��8�N�m��x��d�l ]�0feU?�K�� U�
u�8���z��j��:�*d�w�1�F6�UKj<����A�a�	�r��?M�1���YQ6Z���}������tUN��������Q��]#��E���ڇ[��l�od�e��w5���N4z�wb%�_�y���rOѹ�[��y�Τ*nO���nX{�Vû\l��5XǝL�{�Ǩc9X�o�Yp-(�;m����U���_$�Y��[mJc�d�|����"/���L���]�6j�j�z����Bzg�Ń�bK���L�O��C�x���pb�	_�\����$F35��A�
�Γr1	�@.��Fk��Ζ!V0
�+dJÙ���<�����t'����g�0�9�\��j]�d��(��ۼD��!����ߓxL� � K�ߔ���<�b}���.9�@��~"m(���Ѵ[x��N-T���@�H��^mc��E���#�:���%Z��m<��%?ߤHFy�p�(%�7�D3[�L��.�D��F�(	�4e\�}�����ܺ7� 	~��
�l+�����)���O��{s�pj��L���"��
��9��A�Z�+�M-ƑQ������QN$j��-����� (W�_oc���G$Sy��R���i�XR�A+�ǲ;�@���ƹ
���(|�{B��5ԗ�T_��k���>�nq
r�g�H�rLX��Ҳ6yM'ac	��)��P��)���I͒F!�q!�ķ��%]���Q8U,hH��l�k�,��{R��|M�딄]�ܮ�>�k�o٭��t����Z����Ƶ���? �5����f:�q�K���M��.h�v�^K���j��e�q������1t�;S��#2ش���uo@aoU��嶀�?맚L�H$B��X�ugмw����.�L��B�Kw�g�m���TW�r����KEwn���^>c#�9����)_Sw���1��PK    �{?=GG��  �P      lib/Excel/Writer/XLSX/Drawing.pm�ko�8��]�j'N�M��%H�t��m���]`�0���ʢ��������!�ARr[�W�\ ���pޜR}G	A��w�~g'������8�bx%7���A����� 	5�)���f3
5�w�-���K��H��4��N�m"���#'\���E7K������hzx8F�����+��}X��z�8٧�F�K���$�U�B F���7W� )a1��{Eп�qL%�4�Y�MV������t�&	��`��z�?=MO䯌�(����D��ԯK�R�ͪ�wJ��篯7rD(��:�����{3j9w�D���_/~{���1w8�?z:8;��w��8
NB���s�.޽B+4̤ʿ����hO�["t�8e@~���A�i0 ]��я��OQ��B��qF�(���&gr��WΞ�}����5�NB�8)�h��ȟU��Ꚅ!	���2LYd|�A
��q$D� 	�Ӭr*E`���-k��2]gK��џ����U"d������ �D�;"^ٜ3.�����x���ӵ�9P�lM�ս;X�VC�%����@=��iJ�E|]a�Ary��Y��-�dsA��a�Z���fKB�Ρk�\�:q��dx��p���3�E�d�����1���Y��qa�+ W29˸��J����$����X���a�̣��nQ���ߧċ!�"/at�`t�0�t��wcp ��D/��`pb�  �;i�l�P�k"�DV�n��d�d�g(��Y����^h d�%��l���I{8=EG2�2���m�},@I��rHf<lLH*~Y2���Z�Tij�<Ʒ!&7�mH��m\���� �#�ȳ+q�VH㴲V�A�jk�v��j<,'�UzoN�Q��+b薆!�̕��iB0b�U�Q��3c�ʩ���^bp���7.{�X��VB�r�q�m�Z�*��ʼ������ s��l���>՚�������SAU�~�N9?n�eb���U�X��	ea�``�2��E�;5מ,]n	�Q������ &��$�Y���l��c��)��oB$@F�����Ϗ�������O���H[:W{z'?=;.��������=D���Y�h��٢��ߜ�_�Xh�N,�2���_�d�mI
�y%KMd$�7G�i64����[�A�k�l�
,��rT��v��ZI�~���r/��ᴟ-����j�/փ���]M�xs3ض2��_��_S��Q�_P��N�_MݱH]���_���Ɔ�@Q�����YQ_�Q�K{���ˊ[�Y�2K�m.2��nY���d
[9;:�RS�F���2u��{
��v����U۽)g�k����a�i���}G�=���Dȯ���x��8�^k�"�/5}FA��:!�����l�e.�����i�&���~��n����N�9,aKŪ㸧b5ӛ�
�4�hJ+���U�F3^p�3>eCN�)+���1$���n��:��4�l�J #�AR9dO��K�A�y ��,"!��W����Q\��t<Vy�R	N�O!����rh=��;!χj
��<C���l)�:P��v�4mS��h\�İ�`B�� ���H0�Ȝ��24�V��d�4C�a�u@v��v�B�Z{�
\_�>4�b�3��
м����D$h�F������v�|���GiZ��̎62��p�G�%�bfs�i�نZ�K8��� ,{6�4���2��Is���Y�1^�ʚ����c��0���D\�
[|�ǀ�#�ޙ2�(��~�C������fUőM�l��7��&�Y���"k{%�dN�$��Rq��p���A;.�'6#3Z*�K����f�,�����+���*ܗΩ*�7X��<W�T�K����������t��Ղr�D��~ٝ���%y�JJj�R��)�E�e�H�av
W�UO�.{��`Ѳ��xFٸ�֗A�"�l�t�oTc��sq��vMK�Moo\��y���R���a9P�F�}[����zb������f)J�J@5T'Æ��"���� ���� ����u�Qj@5�?������r�Q%۟���h�X��t��B�kM�;��u��;�ٮ��8D�~��*/�q�ؘ_�V�bΠ��.`c��%@�#�?N ��O�#�;�Tʻ8Vt;�GT�d�`�J��u<���"���b)�?�4�P0z,�!����r	@�;���.Բ��I>��~J(�+�`.R�t��/�<�\�6 a)ũ���׀�u�2�S|Ƞ(�S�$qf�[�r�6s�� V	`���u���-q��|��XY�Á�U�G) T�Qph�&<�4E�a
�L����OR@�z}��=J˙3C�c
X3�Pj��^&l�j�Y��]@���d�vF��-ܳ���(����^�����7`S�3�w��}&�Ӓ,I��c[�)1�@��[X������	��>]\��J��?������Ғ<@Ƞ��� ��­`Ar���җ��,�
�A�:q�3V+Z��7��tۥ
�c�����|�5�
�<�;ԗS��d:�ΧɆPP/�Z��"�҈T�l� �g�o#
��\O(w_�C�a���図7��,������Vˀ_wȅ��*b9��H�^x���[jcۑ�n��?��mb>̘;TqV*�3����%0U.�W?[M���/Ή��"���W����E9����6_�}g!�{2B���<�b[�J�h
�J��ci�. ��£=�v`��s�^7Tj�p�����u���>�8v��޿���Nr�4W~�����,�� =knJԅ��l�˭B�7�I����.�T�NY�|����	���ħ��3�Z�e *0-������"��ƹC~��E�&A��"��ᝰ�B
���z4��'.B�����>���霄���|�>_�Y+
�E!�^ݞ������ᎲG%�����۫woQ���_���L��f�k�mBwE���+XR�`6W!��V�Y�OׇGq����,���h&�����X,�������'�9��#՛*��WI��O�&n ��@��ԙ�
3��f�r_�XPbc
"�"S
f�Xֱ !����(+�Re-�?�v#�抆<��vg��Է�����4B$�X <Ɠ��Y�}��Py'�	}�e�5�/��#Ωx� �G��%MI����mg�"�F���'_s����3��Y�G��vA���;b��¼S�bd;-�����
V��q_��S}��ts�-��5�!�[s#tn�A�	�\�Ǎ.���$�����{��2�KP�-ףYhA��ʖ��M���'2��>)�e A��t�r\����s���tDS��ĩ/`x���ڲ��=�w�ֺ �(�r�+C�������;jJ�ҡ�9��b�p*
�^���B��7��q��.
6D��y2�b�k����@{ \�X�|��~m�l���s���P�?���_�	7�Q��i��kS���Z�$�b,�ƃ�~����Ǿ��%�z�S؀9�k�d����Ȕ!�ϵ�Dq�]�J�^�[Y�\���4�V��[ɞ+"p2�EB혬`J���Oc��u�FFE��B���\`���݂��o1
}e9!�2bSF�����-+3�µ�](g�������v��;��P��l���2D���1�	����1�I��1ɏeDn%�IMxd»g�C<Nw͓ԃ="R�ʠ�}�l��kAŖ!��j�7f�Pll%L�� ���.�D��9�a<�m��(Z�\O�9�4b^��3��e��SE�-�_�K��ts�<�����5���v�t�/���l�}"�oN�.ᮮ��xgNW"�cMj�r*���9#S{�������ȑ�N_��\c!�H���+��E�}E��4)4վ���$�����\�n���x���䡣߲�2)��#
c]������\�@j'�Ki�V\��������ڣSu�$]gZ�o����39�����tC);��	����;ׄ�����k�������` Ʈ�H������ҵ&4���,J��M��R�&nC.vw��U/�����;v��& �jZ�q����]�W:EÉ���O����������Pi�S�s��8T���Tţ="V����ᣦ=s合���/~����؋2.#��x����0^�v�PK    �{?5\�h_  o   -   lib/Excel/Writer/XLSX/Package/ContentTypes.pm�ZmO�8��_a��
ڶi����Bb��i�E���JU&qi�$���Z��o��&NZ�e�����yf����(L���G�D�
¼���z�ؿ�w�;�� ���H	��N+��D�C-3J���H
���[��"�	��bVg�8�邅w3���~��?t�t�����1��-����Oqң�N���~�X͂��M&g�'�CJX$�`�-����(�s�$�J)>D��6::@�T�Q7�n�2Nл^ �G��B�c��
��N1K���n����\Q d�1t|~u����3�k(�?R�o�>�����ȶ���wmй��1� � ~�9Z���i:��"W�Q�+T��$�є$�qc������ҁ���t:
�|��-�n������T6ò����a,Hi6��d4�����,�'��z	�)0&BR1b�ʧ��܅H�:-����"�r�[SgO��"⨧%�tA�D��]�Z'<�������)�"��b&o� l'O�[@�$@)� ����D�h���9/�P.#!�}S�(y�/(����V����D��%�d�
��$��,nXкc5�H�U�����&>��A�OGe��O��:���-O�'Ŗ?ޘ	o!T�f�%
#"c�&�ZO[��	LH`"щ�F��O̸
)�
�F=����#z\E���JU�dYW��6��NS�)}V_VW�y��|TI�)؆��2ԓe����M�O<��*���K'�b�n:h񁮖	����)',Pe�WD���f���U�0�X�s���TH띓��y�z�R���u�Ce�xoYg4�o���$u�S�K������^�TΌe|r2�� C�w���5✊7�H3�uF�\��,�T4bO�N�P�uGD�L�&�F�ţU�j���,T�:���p��b~}�*؞H��'?=sF�Q���`>�5\�H`�j�Iؐ���~ɱ���8����)|���)��g1Z�$d�]�g\
:�dH`�C���8T>-`�"?}�����\Q��	�>�f*�Ka?�Y���'h��ܐ���U�j�7��=���9��ۍ|s˷�GzƚR#��R�Ji����qQ��~����~��o�N��Fy>C4��P�A�'��1
=;�֔�����"um���0��@p������`�3�
��'���eT���L�I [xGg��8�'� ��k:)�2��W�g����s[�Q�$�����R����Kn�{@�nl�7�P\
2U���uQ;�P%�~[_@ۺ#��\�ä�@���ǧ�PK    �{?����
  �F  )   lib/Excel/Writer/XLSX/Package/Packager.pm�\mo����_��\!�� haA�_
�hsA|m�A�+�1E2$U��߻�;�ܥ(G�|�:@Lqgfgv�}�U~�&F������OeR�r����G��6���w9,�?�
�1��S.zJNO��z(��ދ����?$ͣ�EiXUh��(*qX'�
`y\����UN]��2�n����5}�&�x�&MW�zUf�h�[�)�AE��پ�5c?F׿~������x� �
Ӱl�ƻs��7��گ/�`GZq5JE��ɇli��-%?0!Z5:D�̉�6B��
��)�l5@.�/�Jr��pJ7�	�����/l�e/=�u��)���JE>�5Z���
A�/!e��b�����R�+�u���Z�/���&�6	����v��OwZ����4"���b6�j:�k���T�E��3���2��$hݐ��r<Jps�6�ʔ��(U'K:���'j�.$K��/����v�-��Eϧ��c�9HQ��n�=ft�����/���_6�� ��� ��`�}$���d��f$`� )8�V�H
�����o:���|?�#U̯21�'uL���2|_��m�N��
1���g�~�I��K*c �Q�=�}㈅"-������8��?�V_��L ��#�ڀ����#֛"S�D�i��P�p<��)�q���m��~@�X�N*��	Csp���ƈ\v@��'`Ii"El�iJ>lƋ�〈q.C,�Tpc�7u�Q)݊��m�{|r��%7�S��:�Ô~pMt�^H]Lx�ʒo+�A��qqX��ZaY��>�}=Cc��$��v�j %�G�q����Ô�� ��p��Y�o^� L߮� �z����M
|��:��;�����2/pY'l�COyh1�K���l<j�
E�z���-pS&-¤$KdH�2��Ҁ�����W!���*t� �����-+嚰����FeAŇO�DR������-����;8��i�Ҁ{���L}�1����#��u��m�����<�����}bk�o�p�!Vt���ʕ�����~���L��;�Q\20�GQ�uR�䊑�LM�©�:� �WF��G�J�1;u�#�Ӄ�����[�
�����a����P�;��a�q�ċ�� �;dX�jfZ�0�����g�)�*`�g��ҫ)�ކŻ�z�9�� �CN�}��c{O�c`�~�f֢[�Q�Հ�:���cBB����s�jn\4��.��	���Y'�-UIIQ����|p�O�0)M/yO�-�_Y ��H2�C盖bm>�+с5jY/�}�.`��f7U��8�������Z�w
3�6(�"�v��+p�oFIC�5��N(�mͨ�/�9�9B�nw�61iB��#�Q�6��v�q�	Q�n�f@9ߏ��.��r����g�1��5V4����δ��3����9h'��2ĭk*�l���(�ϓ�K�d���� �d0��%�C:�`k�ME�bi�X�8�{���db�ذ,�Es7���?��.�l�զ�g���1���ԁWP]0�
��>^s>�����y��{]��"?`��^#�ߑ�+ːd,M�ۊ�'�J��)�ǲY��
+�x��BbRČ<x�^D�ε��:,�630�O�Z]��f�R	H��d�h˓
�,�\<�j~݁/ֽS�~=1e�~y*��O���9t�}�x���9%K.�Ɉ҃�QM�#Ō#������6ss�h�s��<�?��:�0NI�5�v�H����	U����m�4�f���:��}�L�&Tk�*���8�q��(���rE���.��.L������CݩDy�Od��� �Nm�@^�0V\�������z��G_�Ѷ��>eaSpU<x�L�,/:��#��i��=H����������+�C��\���i��:�U吖�K�9J���v_��6��еpSp�~�j��ׯ;���06�ε�u�d��/z�1�k�zDG��u�������k#k���Z��s�t�^��S~�;g�/�_~s�PK    �{?)���    .   lib/Excel/Writer/XLSX/Package/SharedStrings.pm�Xmo�6��_qh��l�1��#A��4��5���DY�$J%��A���Iɒ��e@=�ȼ�s�y�A�8�cxq�%���^0E�w�vr�ݒ�o2��$&��%��~��pr+c��������f�߲9����8��=��$DJ�2�A�e���2�XB����8�/x�X�a�T�
���c�h02�$"
ڒ�YB�Q�8K���܊F�rOU��ۍN���TeQ��uC4�"ӭ���Ѣ�i߬�)ЪlMX��7�Ю�]5�C���X)u��**)(2�am�����P�]:ڱIɃ�T4���I&�1��[��S�F�pQυm�md�{(S��֠��x��T�+T^��Qo譴���&�j��ڄ*�Pe�$�<�QZQm��_���7K���l�i+�,���Uj��s��3��J°&�=7�Р$B���H#-U:̨a���>Bj'�����xűS8쇻`�Q]��?P�X��miU�'�8�P=g�8���`P�٘lc풶�os�b����+���g�e?�)�[���(��c��E�����>���%��)Ui�����K	��h��(���PT�C����n�u\nӭ���Yh(X�VM+4S`�v�N��TD����畲��]#L�>)Y#7i��H�~��ׁ��-���J�ژ�:+��Z^�!;��-M�v���B�M`Ql��Ѵ�
Л2&��
��OI7��pE.m������F�>��zD�yӬ=֯���s`~t����
	�)3%C�X&q'a�4�׌,����_��a��P�l�	'��&
MXcH(���V�P���<�%�`kyG�2�r]�#\W�s��)Ȏ�R��:��75�Υ���-��<.nxJՁ�(Q8�&�ܧp@�  �(-���2��#k��~�K_C.U>h�@�2�u:��u�S�k�S`�"�1c<�	�&+�t�v��I+
���Iu��6_m���S	��E\�κ�?��	 ùu	�aL>����=��	C�B����Go����������k�)K�_�/(h1g���>�gN�x��EA�?��.�(
q�>eómU6<�veómYV��mˆgۺ�]mH/cp�؋�yU�"���TYY�]���I���eUGET�rC�w��o=�de������ϞI �{�܉���<�hH��S|��+`�^�s2�'��8I.�MBC�F��RL@�@#��x�ΟŪU~������z�;E4�@�Lu[���Ҩn�<M�c��Z���'I�3+�������!�h1��	L�#�_<�K-A,&���ٿ�{����m��t���ń	KF�r}R�mG�n�\�1��
͇w�7���ҵ�w�����bb��Fb�}c����k�5���%�N�V�j*�V�#f� �@��W% r`i K��Ќ$�r')��y�>$�jW���l�'l�񣁞�k��!Qk����dG�8�@O��'Zil��D���d�\���+�B��`���_۞f���(,@��o���V�Y��e�C~G&��=I�(KO7XI,����Bܘ��trQn�04�o�T�Z����C�@<�.(SL�
��v� ��B�	<���D�J��@B�\t!h�N���"���d�yAr唉�eu��<���$7��B�^z��2�U����!	��b�5}Oc�=�N?��p!��@h�a�=XMn\���$����? ���s�������n|��cr�N�Ĥ��$";R�#D�!%���y�i.�)�p�����5���X�[8褊�&TD�k�nwu1c������aJ��yLf�x�0��ڑ|B�k�lp�_Y�m�B���]%��,��/��v��O:q�%�k�~:���K�zF�o"eF1w��fR"Yk�ƦR��AFY�N~��5�B.���^��}�s{A��#޳Gf���?v����4��>�D�w7ڏ֐��6wSyx �y�β�ܖd-�:�Ź�������t$�\�o�Ԓ�� �E���Ad�S"E�Ne�w�]�yTj���]��㼲��A^��	�j-��J�9�Gm㝘|qب�q�Yl#�V�X����wb(T�N�8�F�����d�}>�˼ڊ9M��ݽ�z�>���>�Dk��{H��{�h���EIIu�f5�5��wl�'�p	(����K��Q�8����#0Ĳ�"@=�<���W[Œ8�zw��nk�j{�F�%�x:��!Ũ�8�"NJ�2S).����b
3�i����И���5#%��D�UV*
_��ZӃZZ�rr�8��NOTIP��u"KS��U�q7���7��W'�ր��J�x@�?��f�n��o8]�[V��� ��Y\�E�U����+.%X��Kb�
����DS�"S�6� �4�"�f����b��vR��L+����q߻�o)�-�Q�xgy�e�x���yE̅]g��8F��r�<n��
��0�=Ў��ėͬ@�����2c#�t�8��02���kw|�qhe��0+�rqY:!�d�V�чv��s$�mY�dag ;; ܖ�8"���I����ݖk>v����ZX�7�
ÁTg��bj�ɲm-�@X��
�$���SH*��b��Xz��^�u��>5����\$]_������k[4N���6��kt�߼�0����B���8�/ˌ�]a�!�9Ͷ�bV[Y�w����ͦ�nW"�{���wb�n&.��[Y,������Ưk{Wȸ�-\�h�dn~r=i��:���7�G�R�����j����2��
y�q��=Ɩ[��q�QId�A.%3�R����p��דM�s�ؼ��N;�v�]��zH�x� u��oj��a�T;�W�����]sK<đ��-�E����ᰄq=��%Zv��ֆ�r�
˺}����rc�k[�ڡo�?iZ��3��/�յn�gU�9M��b��|�`�7�͢����'�	]�>gu�����#��Z��1+n������=��6݂�uY1X�ȭ����
�i5U̣�.�A\Z3	8o�� 8��"_�g3�`�|�r����{�)��2�w�HS^������O��Pv��W��Ų�J��"|sR)Wu�!��f�o��l��h���r��4��*��Q;���&����*�N!a:���ӼXz]��s�wkCʆ� vR���j:O2��a,���#��~ﴤ���r��W�<�?���+.]Dȴ;4rݰ/^� T��~1[D��k��p��ӧ9+�V
�bQ���DnmYn�Ďa;i
0N�I<��c�v�����0`X7�̀�ۋa[�؛��d�u@���w$%�:%Nc�%�ɻ�����}�ш�:r�=���UD���<r��w���=HH�q�T�tl����]��v3x�k�*�k����?dx�e��<��D#.��A�1RA��
e�e�jHH�#!�G�I�)�#tFU`���y<t(Ԩ�jˍZ�~}ʃ�x�8��@ǡ�ˏ�GU.Ɔt�{IH"��<���h��yt� ��`���T���3�ϴ<�T����!�5�r�z5�q�+W������.8��̭>'2ZRH�	Ry�`E
Vڷ��㐡X��a�z��	8���H*���
'R�8�0����OF8a*eVM���ӈi�SF#�QF�V�`I��c,�7!?&�D�,�|HQ?� SN�X�=�hU� _$T�V*�$�]��!ҵ[�N*A=�^�as��
`1��k:ig�h�l	]Oy����y�|�,�Id�*�/<�?��i�FA��4
��I`���g��i$A/CwU�ڎ@J�~�:K��y��)o)I�n�����64N��<�� ��?f�CCMz�6Z�m��Cf��HkpJ��Y��ԫ5���>���<8�Z�8���ƌG��L�t>Z���ݔ%�Ì�{N�T�u]��2�U]=�#��������0ȭ�z�p�.��s4�IgEg-g>`DOoR/xLxFb��`����%'��:Ŭ������A�]l����8��mwJ���ݖ�dt��0tb<�ַZ�77��)�y�`0��S~�=,��a[[��Fγ J/�y�k�Z��/�o��W766ګ%|s�o��;���z��o���y�7�����=ï��n����x
�|t2���Ff
����x'O��-dWJ�E��c.� `��v��$��� ���PP��.���tɓsKZ���p�p>���S��|��ϿA/�?{���O��⫯^<������E����������?�����c��"����?��k;P����ٿ�}���~��?}m��<,�i'�]��y�Y��x3�� � iTP�N0��6H�y��ۀ�$�%]�(j�
�V�o'�"A*�k-׾�(���Η#��w��j7��p�sF0I�e?�f��x*3��|�`{Z�k
�O��z���+��.���ҼDS�?]St�����́
� ���ўÅ
��8�ޖ�������V	1�}�֕���V�#mr�@��1:�
!{*��5����5g�����2N�)a��zW��
�n�9���͵U�p��<��L>�f�Zo2��
M��(X};��Q۰[�h_�Q���и���l�=��}4�($�r'+���t��Ӭ�v����� ޗ9|��\��W����n[|�~����us7���A�f��N��&=��f?e |��Z%�VI_��BG$G���K_���_���T�����j�PK    �{?��  �	  *   lib/Excel/Writer/XLSX/Package/XMLwriter.pm�Vmk�J��_qhVP�����l��tm�u��'f��Lv2ٴ����yI�E��pA2sޞy�9G�9p4y�)?{TLSu�t3:�#�Yӳ�o7�����Q��]��a���D���e3����	�M~��%,IA!�( �
tz��H��M�(�
��X��RĚI��6`,�7�֩��~��=��[���3�E:��¾~�s"zR�m蕌ˌ
Ml�0Q4�]E��!��k�zs�1ɹ��X��MTB7[��9ts=�CWHN��������?��B+k�^%0E�V��\*{3f5&*wo��0�f��^�t�s��&$������%�g?�ӺN{h�'�'������~��K�>E�V�mUi(c-���\#l�������ifE�$��/(Op{����J��	l�גS�����[ե�4��tʨ�:z͸�O<����gO�M[��3�u�q]��_Q0�m�L`� �����R�:�8UJ*�C�
[K),*aqJ�#g,є�]� ���[�ueףSk*�"��{�A���3��Y�m�d�i�Nnhԉ!��K^�\�� �U�J\Ò�Ra�JbU�M���'SR�n��(FP����ڇh�4��D��Ӈ�}dH��I�8��h`#�mH�2IPjAS��ہ�`�!��s����V���}OԖG5z�[�7��ѽ0
���=I�����nT�reZԸ��]����ƙG�i�j&+/Dv��N߳t�BڎY�
|����y��݁�r
��1e�2�TF�'��%S]�?�[�y�匶�,r����:�n��u���={A�� �pgh�I:�i�S�!i��3�5ѩ� &Ƨ̺e�|R4��C,�����n���C:�7"_H��A��n�;�}�M�8��OIF$ه/Y��ף8'�%�Ժ���M�L02�F�����h�S�t�,\
zFa"�OA��Ku���Y� ���#AP(
�Z�f���'�ek�}N$��=
	G�����ռ^�5zV��������ST�[��LW1�ӳ�aSMd")��� �W��sJ1�)��H ��1�±~��&c@�sF��o��fT�D�`[i�0�Ԇ�6���ʩ0�/�Ih���	�PMRfI��̗��bj�R˶s��t^oxrlqka����Q�M�f؍Q
ۥf����+�&(���d�����[�E/k��cx����ܩz�2�N��;�1�UZ�m#��=�#���V�4��Љpg�X��W���_�%�)׈��57���VpuU?|�q��
�V;�c��ꇟ.�6M*<!Lp�T���9n��!eK� �5�<M��$qga��BSUTF������T�L�GtG��Qw4�.��&V��3�TP_����ʵ��_��vժeo��a�l��Q������xF�����OlCH�T?t>aí��\� ���<y��1|(���k�~�f�~F�z��e�^<P���*���2�ƿ4�q�z�%��"��xbn͘	e��%K���AlfFm�R	�d覇w�S���}3DY�M�~Ycq��梲nf*q�'%+	� !w�2?���:�^êO dx�Ao�l��N�[zv��96Y�C�8e��?5����lQ����'�
�g����{�x[~,�2�����|�ݞR}V�(���nb7Ǐ�r��6�ᘊ?�})+�'
�N����r�/����9a�J�9�U���̉"�ۻ[�Ӊ���oȢ?k���ț��u��{*�E5��hګ��wd��6�+��U!n��{99�;�EP�Q�ؿn~i� PK    �{?����%
  �&      lib/Excel/Writer/XLSX/Utility.pm��w�F�w�Ӑ�r˒r�L�Kr��@&W�귱ֱZYr$���o���]ie ���]���13;;߻�{QK�a��z,��Oi�˴����iFa�t糍�\���U`�.�u��W���c�j�4uh�C�e
�E<��$�`���8rk3��1����Wa>]��G�|���:��:��o�w�4���'b&R�
�1��N ��Ti�:
�	�X�qZ$�����g/B\���+8��f�P��l�f�
S�@a�@���8F��5(�E��nɍj�j��NsU�v6)��
 ���P�72���9:�����XP�à�Dz3��*� N,"�Q��Z�<?YD�y
��K�Ҿ�������4��Z%z���v�6��A�_����;�j�,h6ڽ�:��A^��Z�������^g���܄iy��^�Rg����\d��gB�R� ^��e����%Ő��-�DG�\d���Is� ��V�-9�������
�I8�@���u�`0��-���mm)���
�;1Ƙ��Q+̦�ҭZ-n8�y΋���S�>�\�L���`�
�V��rR>s8z��mqJ�qn�RS�v��_�R�K_�+eU�o!{�b%�̂Z��:k۩���.Իu�Px��7s��e*eNam>l,��7$�F���ڊ�w���y=�#�k,^��L���"�n�䁣p8L��c� ���'q�
��G��<̨�Q*f����8o����Om��{�+��ޮ�c	.�z�Y��<V		�5M��{
;�β$V,��v�t����u�X,q�գ>��)}9��2s��\vq�E��ѩ��\�2����UF��0�R.,/�>�U7GoL�����1�^�0c��+�!-�"-(h�c|��(��YÎ�=�T�F��ee��Ɲ�	y�n�N�f5�@����g��$l���ߛ�bL����UH(���7+�7����͋�!�X�U�a��;�1���������:ۥ�V�u����P?���B��g��,f�/��k���<�}���6����RޘK��)lT\n?�sF$~��A���;��������U���jIy������f�LΒ���G-[�(z�щ�HJ��R)栬HB�w0їS�J�i�u�)U�T͐�Hc=|Ѓ	a��@�^�ђuRn��>�D��6��t��I�����ٔ<La�l���Y���.�x\��An�����/pJw�Q�V�Z뱺�4��L�t�>�߄��&�F�3a�˔5��*/�S�eNw���\v.��"A���N��S���L���Lt�Pyn��7��U�{�#�}o��PK    �{?�a~�I/  ��  !   lib/Excel/Writer/XLSX/Workbook.pm�}m{G��w~Ec�#� ˒0^0�{�}�'�p􌥑=a4#fF�q~���~�I$��p�#�tWWWWWWWWU�I�,}�qt5�ӝ�ER����߽�y�m^|8����t��,}��cA������>�_��[�����[�?���m�T�Ҩ,�$/�%��d猒.Tvoq��x,�L����y6��<�Iu�Ux�Ϯ�����^��=�����"ߏ^FӨ�:���(��OF�(���9U}����8�"j%� `1�|>�{(0���J�׌AuC�4�D���*����,=��Yu��Y�F�n��X�����Q��*�"U��2*2 Q�gQ1�o/^��'i̿������x:/��;�'���b�.�mT���X���,*ʸ�������D6���EW�<���jY�㼘FK�,x��9X)V)����]қ���4����W�
��*��(O<�o��yo��B<y����V\��u7:��͋W/�n��܇!Y��{=?K������ɧ��q�BL��"�L��[]O?����%'yh>���/�g�R|�u�bz-6Y���"� ?��e�Np�V��Cj�å�ۇ��8�p>��9��w�S����z䖖3����lO�r���]���ye"���b�e7Me&IQVv�@�7U��fA[W�!��jQ��(�K)\��/�M�P��(�E�pr�ط�d2)���E8Qׇ���{������K��KL,8��	[o��-)s�iiZ|wTڬ(4."\wʛE�4ڋ���L.o67�Ҹ��Ņ&yV��7�N6��U�z�
%�)h2��à�qTE]o��V�*J���o�Y�q�Fu�3�a��uT����?~�T1I;Rh�^<�	u�h�V�=�C���rDIR���.���~$���iO�%�HJX�D|����AՓ�h�,�DOBb�����#H_���(S�u��/�����:�Hq/'?~��1��Ս�ዉ�v���8�F�$(�@��R���4[}��6ttK�i�<�%�A�ޣzG�j���q
Z�!.��(�P�K���h]��
L
��R������&�Yz�U��q�B@	2��K��ܣ[7kR]��1l���4�KM�|N,MJ�9�@�O�vS�o+;��h]�3f���C�~�*4�� �a5�}ne�x��*r���j*P����
A��C�>E�a$�"L@�/�)r1,����FP��
Z�hD�q� �R�����8��bX�H��)�k�K.�U|U���gy*3C�もRô�,P�PStAUѹ�J�>���It�#Ic�©�uD~�+h�Dx_��#j��q�j^����!)�Xv]�A6�[�(MAmH@�%��Y5�Tz���)�Q�r6.@0�)0Tu���.��.�Z���ћ�^�߮-=oM���n�$.+��d��6i�(��>�56N�Y$5*]WP�
��7�H6���G��L��Z����^���	r/�����ET"�����8�cԥf��O����|��E�\�1�ɂ"������/G�����jv��~f�uQG��2E�v�r	�D4�2��R���ֻSA�/�����G�-v0'�A��Q�O<i�R�D��@(�rKhKޓ���)d (5�fd=}������ݓ�i@�����a�헺�r
����4����' �X:�|��KX5gE<�*`�˽��E���yӭq6j�b��j:W������
���Q��qU�~�aG8J
T�
����D���M`UR�/���8��1a�Lg��.	˭�Z\k�l�:�vJ\e�s�ĩqx�dI5$R��ّ�t�O؎8�\���xo�)���A$T�2�4�f���5�v�ϕ��_�����z��X��,[�i����1O����f3�[�y�ǂ�"gm2���m�MT��B�+���V!�7�Y����@�,��(���%J�FM���$��|�d�K
�����p�%�J9�"�>���.%[��8�5�6���?��y!mN�#W��;tl'xLP?T��'
]��F�젥�1�շ�4� y[�a�e޺mڰ;ˣ�H�#:���WIY}����BJ$x�������I��f�m���!���W�;i�8`z:OEBk��]�
�)m����R_�4{ک�
}�rP�Z	YR��.�ͣ����_~Ye��u�_���J��ټ�sFG��oQj-7�x��L��C�%"M�Ϳd�@�0�pF\oJ�,���8�P��vG5,L6G7��y"��uu����_� ~�!�A�:��$��^6��yrk��6�x]�Ӣ U
}��g'���+��lL��I�켺�H#	ʂ�e�~T�1����B��E�ⰴR��w�>�A��e������W׍�G�������u��}N�����ޟ���?w޿?ݲ�RjS7��{�D����+�aXu�g[��b�7YTb��M��w�.8Yj<O7�d��g��Zc��
�O�]D%���FecM�@cW�7��0t5�G���m3�n�7��A�B��>>�_'��DF~| ���r��&S�"J��faFIi�T��H����)%»�6�Z��<�Z�=�x�'�?Fx�]W�[/|(�d{���\�-$&�9M�
�
{eW��iQ&����4��' \S	/.
�C� ���?���B�$�i���_���8f�8�$<=A�SL�
��e�c�.��f�y���II�ad��ڻ3g���(l���%�5�-�B��<�'�䩷.5[T��aoI��y}w����(��
�x$?��(ZS��

y,�S�:{�u7��g4�\D���U���OP��W� ��=�ս�
����6��`vi�&v�������R�5ۊ���
�����T�~ɂ�h�4m�.=$�?|@�#ɻ} �u���WT���m�q�]Њ�������0�&/h�sc�}R��1ۓ���n*[>2�c�x��lм`����{g����^MS��\%=�UX+�Y�d�Dl������֞�d"��W8�~uj�,R�U��aڑ�6�%A�9�A��;ѻ�E��+@��=p�N&�U�a�h�~/��[Ô�7b[C�?hD��^#�u�������w�>XD��^ ��h�ÃZ���>lķw�
��e����K	��+���t�����h��柘Ǡ��<�v��Ȩ�	%�/�0���Q��r����}G��N<m��Z���X���oc���9|���޺�6w<���;u��vs�ȫ�i��xЌg�i�[͕6���#A��v�\�q�^����m*yqȂv��V�Kv���ϥ!�g`�h�v��Y~��gk�}�('���.�t��?Z�&�ҧ��q9�)DU̢��ә���?�t�w��oO��g������=��S�V�0�����
?�W�R�����I�`4Tg0�0�	W�ƶ�M��wG�q��^9�����Cfk��)y��)� �˸���L���qRA�V��d �D���1���o���9X!A��;}�]������x�!��En\�ߌ�)��ޤQY
1�%ї��lj�HxrH�z!������S\H��7'N.Q��!nP���t]�DU*�};�nc���3&�D������Z '�%�/�kҼ�����,W��$�����C�8w�� Z�MiP��@����&���_�{nNf��H�avM��\i*+X�P����`��턬 ����� �_�
�d�P���R�CQ�-��sHX��@a^�Ty�c�h��%%g�xz����E
ErĲ�+��9Z�,�P���l9
��"���@��:���+�����iO��?h����N�Ӷ�W�,Ag?]JQ#+9�S�Q~����Qȿ?����g�w�7T�8p��W�.�N>��w3�@�,Nrl��d�k�tp�_���ɓ���U����w|DDrbh�uh�[�p�Y�c��E|Is��(�MRl�"��z������2�Y���c����*�B�P��@.圅���9���YT:5H���?K���	�8�Jǝ\;%�b�j:R�%�ó�TAUU�m�C�X�Z��͎al�{6�L0	�z�-\�������fƊ�6��#v���{gd��C�~SGA1��vK��Jd�	y�&�q�z���#���7j���s��<�B|G)�vX��nn��4�m��3�Y*n��
NtA>-m0��k[l�V�^c)�CW����[�r�*Un�H���sM�`�%�����/46`����4�x�����@�hY�3����+4��؀-~���;�m\ҭcr��+t�r�9�_"E<f�ȼ���N��G���7�-eok��h��\��l�Ej�ӱl�n���I�[UWsȨY�:�?���^x&aItyT��7�Ul���>��t�	 �w�ΣZyvC�N\Cs2�߯>|T��='�X���*ͦ��1a�<�"<�ju��ґ�h�N-�n�:��De�-��A���ID}b_PG��M�1&�/�X\`�E�N��#@#��k����� Ժ�M=/p^.j��՚�O`�h]��Pʤ Hw�8�9�Vkp������~��<��?bX�I��N�������ĳ&�Wܻڌ�*t�wބZ]�sh���=�,��@ka}ySn�%�?�u4(�DP�&�{tM��g�.M�d1��S4��3D��L,��`E�#C�pL
��?�]:����F| ]>y�t�dX]YÆ�)l�J��}�����;���L�O|�.���D-�ƅ����⵺n��fQ
2���5�5���6�"��}�6ěf���I�.��z��.-e|4��P�LU�e����M<ʳqC-���ʓ�
+��N�_�1���Xsk����h,��-�|}����Į#�����G����0k}m�4s��[�D��
���r}��VL�r[i1���`�귤�Kx�F��3͈3�6���l`ͳ���<,N���&���7�*��Et�����ݭ�;A�Қ���S�K���4�l�H`(���d�������@l�����ކߞ�6⠛�&�TW^���y�n`�XP%^Ԕ��ɭtL��;~�P���Y��B���l� 9=����3�bJ3tD�>�u��|�z6d�?/�ɐ�����T��l�������#�NW�dU7��]$Ud�}�"I6�v��t�n�-L?Wݖ��DOt�.�mQg|��j��Wy�Ǧ
d�+w��
��8�=U8����>�դ]�Ŷ��V����d���7/b̒�QY�Ł'�(v�bEZ�my�:��U��Tڢ�]ۡ�F�.���t�]"�fnuՁMRu��Tt�M�t�����9��c�w�z-:o���lx�0�
�.��P^�]��̅���O�5�X�O�
�<6����~�^������ߝ;0k��-���W�'3@/F���?��>`�����zGC�Ĩ'S�����𶒄˸6��N����a�o�!ջ�z'-GV�UZr ��d���#~*�v���N@�O�dI3�^��J� �v�_�̼��6t��X��]��"`���ժPjlĽd�����Ր'��y`�^z���c��sa�j�-�eШ�:P�]�b��&(Iy��U�������u##�Ԛz��%�i`i(y��c_kS�Z	\���+i�vh�]O	�*�g�1���M��.�粡2���������&��s�`��|]�tI�)еW��L�ֱˮx3צ��1^ف�Ap�A���!��y\����Nq���ZaZ��7�ń�_�
����;�_&��?a1<?ay@MH�j��Č9s��%�8�o6��E��k���PyRV�k�Y��n����}��" ��Puۢ��[���]��N��J+\���Q���������v�4���Ih��ޚV������1�A̝n��|��j.�1(�-�T�2�����P�Y����H�
�����8����!4�z��^c�#���%�
�(Z���¹�Q�C��[NO�j�:j�h=.��������N4�P�*VH0�Pf���򝪈�e}t�`�z!w-#9+�r�`I �:/�kg�L���_�6�_�vZ;�J9���C�6Ŏ�)�^�C�o���/�Ӕ�r�Hq6�� A�b�A-c�8�H��K�@S�=�]4��iy0����
�(_��[�2�����g����"S�·:���瓣^>{���b&����GG�F���O�R���F@d.W5�?���Fk�}Tm�na��E�Ǌo8�8R6s���}DN����2���u�&�uɞ<�׷5�s!�j����,.�Uy���^�,���lr
���S��y�0��@!Eӑ/����8y��e�� Hy�?E��q���z�E��*C#_�c	G���B��H�����E��Ǐ�)��b}��R͚�.&{f��ި���!(-h�L���<�6����8!n9I|���6>��E�)��%n�P�d�.�q{�)��7{@�簈br��ѱ����̲)�Q�fB��i&�b�Z|����h�܂�,,�͜V�����'�o}�&���B��g�jۀh�ł�Aj2_�|S�=b�<�H�)���O�6�W�8��S��������¤��w�98��2��3e��pu�}�y{C��h����@8K2��C-�ߤ�bf���� �3��o���J�r��>�vJl�<���C�܈@�;�-�6�2u��Iz���S�V�J<��.kr���ϯ_��2���%_��]���1)�L�
���j�V�#�]ŏ0"i%��	F�p�nb��A"̩�Bʷ<�HP�8b��FGۀ����^G��J�����F�A}���r�� ��#��ٳ�R��33p�AkC����T�ژB�i�$>��uۨ�1�>v�P�`CC-��ֻʐ�-P,�sg쎔�n3�G�4�R�;����.��0x�Q�H	�ІmF�x�
����䲟��yh��^O�$�]�����8�AW�����*�K\T�Ë��:�sy��|2AwMY{��1�B3���8�^�x�J7Oy�8Q�(3���4*>��o/�����(���e�uP��HW�ì��}Tg��ל6
&� ��� ��)�/1��F���u����+y�U�����#/�2v̚�
]��H����ƢU�࿉D-��<�qV;'
��d��6��nS�E���PG�ڨ��X-��7���1�h�6\��X*+	B�7AQ�����<�gM3X�Fקnm�&c��l��/����/�9ʴC|��ݻn0�[Vݱ��/�VOּ�q�ꃷp�V��je���q��̶r��(uҼ�c�Z�a�
�L��8�<M����ʯ��ʤ�JC�g�V��n�	̿(C�~"�+d��
��0���g��e|ج*�*���zx�I�V�O��Z%�l4/�/�V�����QC*awVS*�o_���U5LKo*����ƹ(��=�hP"��
��b�$��gmV�Rl��^�=�dT�e>���ǒ��i4��hJ��<�m9�"Q����f�ٟ^ٶ��%� Ku�__`��չ��ӫ!w��Z�I����F����>ޏ��y���+����5X ~��}]Q�hD����)J/hY��k4:5ju_��V���-����.dX���aXm{a#t??�[Y��!��q��2�K�m(/m�1M��Q+�+�R:������,_Nk��yy�t��cuO�z��8�0c뀔9�B��rJ��ҶOQt���&؏#�WZ&�p@�V��px���p��b�Ԡ7x�� PK    �{?���\  �k "   lib/Excel/Writer/XLSX/Worksheet.pm��{{�6�8�?��+��eK���#7n.ۼ'm�$�i�d��ms#�*)�v[�g1 ��4J�=�='�	` ��`.צ�<��Q���8������$�����w~��7�i�,{�Y�E<~�$��ۣ�{{PS�����ɵ����_d�G��a4��Egyt�F��OhP�V�����X$�(�G�l���|�L�yt�.OC�����E���.������`���F�_v:����<�F�������"�����>�ƫY2_��K|� G�����F�\UX$�t�N.h��DMa:��`�Z{���h:Dۋ�p7ڞg���OVE����Ոv��b���%�~�s�������~.ԣ,��˚
�TS�"��wOΰ����t�./>��_�:�ӑ�2-�Q����i���o�
�K��lU"�Y��T���)^-3%/1�
GjE�
���75I%���)�����4�\
ة�$Nᢨ��Q@p�  �Ni�H�yi$�ܞ��ё�X��`V��M����2�E$㨨]��婒��B���b_��O���v�eoT�HIs�c��"��E�:ғ�xף�#�?�~5�c�o����[�a@_��9gs+�F�W�[���LcP�زZ�-Ɗ�Wq�����A������n���'-�|�YR#�{��XW]~���TU�7O����
�&�\��?RL^IR���{lAӽ��1E�hoz���3��D*~ˠ�i\���[*W�n� u��Z�������u<�O�Rfh�0ͲIz����$�EA"I����ݠ `�%�ΎQ�A9K�,7���8��'�i��:fq��%�d>�&�QM;��~/�6�ę�TU<]%d��s%�V֜'�7��gj	�Kǌ�����~��g�%�Tg���c��S��y��YQS�x\W���uuP	PG]�����i��u&�����/�S�1��4�I&M�zY^^R�U/W�Y�o�%i�+ׂǳ�;#����Z�k�ӷIn�~���I���\Z$c����A�M���Mr�v����>�M��K�Zv%`�%�bk�u��o���ك����V,?����d��	h狨����<;�K�E{b��j����-�����tq�O�5�t�aŎ^�g�Q� 6�^F����������������D�Ζ�3��[%M����A<O����̗�s��ΧǊ�[E�׉&07K�:۳�����1�?_��>�(�VE��m{�
[�J5>VU�����pZtE�\YQy�O�U]�17�t���lԿ��|����`�d�<�����w�7���"�C���h�����cQ���� 4�SQQ�zpU�K���7|���='�F��?a��=�Up��j9�����ƽ���;�Z����ʥߤKB�:�b���4ֿ�ù�/f]@HrP^^=�	*�NQ��t~2M�B]!(��J��aK�|E�	
Xl�5�"�TZsu����Ũ�
�n/:|���"��o��y��Ut��R�,h
��ϖ���K�oqp�*�cb����k{����ٵ�زQH$8DOz�$$�Y��R���Rᯙ�Lz(�y
m-�|g��������	|ռ(�������u0p���3t&^�~ɍ�k����{zBJ��3j$�к�G4�y��N�$-h4 ��R�=Y��t3T�K�Z�?a��V(�HT�,���̺�X��I�	����ց���z.v��3���ː������S��/��h&���+��#r>?��;���PH,�_b���M�L� {�.Ko���P��P-<��KO�b�	��ٕz�q�бK�U�z-z|,T��'.Z�G���f�!U���A�p�`C	��Cg�%ER5QZ�d��uG��ve�*)�e�A����a[-ԅ���L��I#�77�#���
y<[��L���c��K"8����(y�F�,�-<S'�P�"�=y[,oYփ.yï@�V 4O�b������TL�������~���Q|����E��8�20M�${8z�i��kv|������m5�)X-�����3Ā����l��Ts+VF�,F�f��m#�`���3�Ы0�<["���tyϽ�KuWQ���H������EO�Ūy�Ш`��7gq>K��B1�#���}���4>�I��Ŝ6���_d�2�S�1>!KD�D��J�\k�^��������-s`*S�e�q�H��ԕ�0�2�]�)X������lB�]<&gp�.t���0
50:U����:��K��U��Z7>L��&��Ve؄�c���
�n�V`?�?�^|�H-&b��]Q��+��OJE�t2��:4`Ӧl�	�R}/��+`�D��妩�7U���sh�c�谼%��]m�1�vƷ?Ȕy[��v@�Ĺ���n#}��(Al�u�1���>�}+&H�@k�)#;����5����D'k��:���]� ����j@#Zo��}��a���5J�n�G`��N��ƍ}�w|�'�<���vԳ#�E�=� ?C7��U:�D��uĎ���[�A����z���e�}4���/�L�֣g��i	��ыZ��`\PT
��F��:�2��фf�H�ג
MkJ����)> �3Z���lo�Ù�����Z&��~`]��ݮթ�w��?��%M޻q��2tTo���Ƃ���-��.��C�r�ֶG7"�1�蛽c����U}f`z�l@éc ؖ�[C��O����T.�#�m�؈r�QS��*1�Ɣ|3ƫ<��>kDe\&�v����;�����M�`��O�ѭ}�p�G���&@Y%��`c�cs��8���5�=FSO4kQ�0�%�]�M�3Y��o'f�|���:�L�'���Px�ʰ��Q��\[�<݆͍�-փf%
n�%�#�ڱ��w���ZZv�91����s���P���@"{G���ٮ�Z�A<�5.�7ɼ+��/�5R���;�N�r�Xh0XE��][ i{��c�2�n���_X/���iX$z��g�]���Q�� VhCj��$[A,���ٌ�� YT{��^�S�N�d��Ԯ�
n��l��Q�S,�ڼ'y�ZT=�!_ٛ��#!��Ԗa�����x �n�Q䄪܉�Q�/%;!nQ�����a4���3Q�E�sE��٭��5���}�M��n�j
��C[���^�����Vk���ﯞ��9Q�
)�e��tp2	b�y�N�^����jD��R	� �o�>����vv�\�C?�Z@����i�\
Zx�m�����t���K��Y[H��ǫ����w��&�A�}��F��P��l+�> p�@��VR�+:�O�����l�T�~�-U��w�Taɋ�	U"0�ҥ�,U����u [�H2_j�>A��H�w���/I_�7"s���C���Ah�($����m]�){��Pw+^� g����@�7
H[�#-E�Z��y�t�n�A�d [iԏ�v�>P���K�	�0���d�G;���M7��N�̤:��t���.��+���0l��"Y�P����!�$�V�4Q����tB�^���ý�؟z,n�O`��q���Q�ӿK��_�'��Sv[T��ߥO�����$����������t@�n�OT�
W��Մ�s��y�_���B���n�T��Ż{ 0�>�i��
���"k�������P�����7`�(?�B����1�v�$�BJ1�*��T @�͢^�j�EwC{�+P��U*
��i��@+��%X�)vˉd����˃5��Ǌx��(E]?�fu�������7��l�o����~����a�H�T���J哕s���&!h4���+��z7GTQ� �r�F�Q��] U���Atk�(3�?�uUmD�p� ��!�M�����7����:"�Y$h�+���q�Ʊ���
;-�@JVj�<�Z,�ؓ� >._�$��$�@٥����43�JF����7�S�q.��X6�Όr/)�4�I��u<�pZQ�+! F��_�E9̊���U�=��_�B���pA�ˁy�*�ꥨRˍG2ĸ- ��89��g�
��#`�]P7AN�D�:8��}��� �NM%$��G
4��UX	�_m��<u�@q���
���T0�ɖ�-���T�Nd�0���Lr=�G���Y��o�_|�.k&�6��X�[���`c��:|������q�ֶ�.E9���]�%��y_�[�����YP�s���g�]�jF;�M����_ou�������j��j�y~�|���ˇ�k��F���u�Q5:].]�_������gO*8���/�O_/�_/���vv~_��*��t�.��e�W���?���y���"X�g`Uǿ��W��򟝯��������{�|y5�+��~����d��m�������f�8�]4n`���&�\���mOe��Lt:�.&8X~��cs,�#t!i��7*9 �s�\V��<	�'Ng�:�1�2�
����1	�;��:��'d~���
���0m�5���c�C
�Gɵ��<#7�:-�x�&�G�Z�"�p��{�va�t�$�s��b�@�v�����`of�1Կ�,��ЯYL�v��
� �����IM6|sB,_���}�,��?��/|G��_�j-V(q��{��y�;���2 ���e@3�.�>��8�$����8%�si�ԑv�[0��\0A�l]������f��=�ܶ'��8Y(�ts�f�T�6;�`�
�V"��`� ��Ƃ@J�q����q�i8����6-�[�d�O��?}���e&���V�+�g���p�W��SH�8Awd�����nnx�j	��UZԼ�jN!3�Y�|5�i�����9��_W�eA��w�� Jo��K9���ԯ^��]�?����]�7�Sh���aN������1���ˍT7Pzb�����S���Z!댺�諯�%$�}�(xȓ���R1v�J����CsR ;��
�@+9��&x��	�;tHҒ���b�y��8G��;�S|�m�}���q��㡄�?��P:�nP��Y��<����xra��(A��H�,��/N�A�* �z�8C��(�eH1X���߅��p��/Fz	�
s�aԞ��a��!^���f�
�QYB�����0�w�@�6�]�h�FZde��'��X���O�s�f�\���_��
Ɗ��G�b]��kИbqkw��-ԅW�ǧ@�R$3H���(N���6h���r/�
LlN��9UA�`��-�����mi�B�БJ�x @�����e�3�Q��s]ǯ���&砈7~Y��q�;ؠ_��8��-h��-�E?r�F���9�<�<���}ɠL(aa�(�@U3YdE$�J�L#g����T<�;�O�i� -<v@�x୎Tdv;���lUp����g0�}2<�r +S�J��.�`�a�@G�I0�T�q�A��lI�|x�����f�7�F"�F4��I�D�V���.[w�1�P
B���|F7������tk?�*a������>�M�pHH�
I�-�8�s�fK�:p�6~
��2�iB*s�O����
�
�|ӈg�'㭍�l����a��aNQq��f��"�/�	#C2]�b(B
�/%GY�H���OJ�Q{�����l�R ��pD}�a����C9Ĩ�:�q6[�)(H�9�,3/5�7�CpMc�v@{�Қ�M	���D��IÖPը:A��	ͅ�F��|
p�DU��;;�L�(��hI^q6_�1皦30�X,�)3OQ���Kp��V�?[E��
�B��H�������Z_P|�c���tm,�ҕ!E �~
i�3�|���|'3a5��	��<`� �f"�3��H��@��%�$��0�Gz�-.8*!���-NG�������� �B�iѩ�Z�\@�.i�o+ �e�c�$�[��H����n��2 ��5UH�WZ���fDt�P�;��t��@~|�ĿY�E�h{3��P�;dk��IIOn��U�ꌊ����0҅���p��
io�9_P��2F<��F����е���qT(�{����e��QqrI��u�v�b�;?[LM�&�RM��Nm���-
V��ej� �U%Ї��a�p�ۏ��{$#G��E7���ba�n�����~���vC�Lv�/w^�|����k�(�y����fq^
��TP���凌�RuΎu���Z�l4ƨp�W�v��K4��s61e%��ۊ>�$����V�^��OX?{�{�L���'Fw�ӻ)�o�MH��X`�V��[ZZ�B��) �8�ꚂB�$j��^���+�IW�u~
),&��b�W�΄F�F��y����/����օ�ٞͶ'���{��^Q�e���B�N���M��K�Й��?����	���s:q
C&����_x�c���X ��[d�z�=ƬG����X$�X
p��(��`C�nណ3p��>?Ş8E�'�dtCQ��|R��c88$%Vjc�n^�詍�l�8�"�t	m������h���~;)��A�?��}�9;�L�M��k��!���}!e�F���&�nƚ� ���it���B����I��,�cF�?M�T��P�λ����=���a	.��)�X/�T��UqcG?ze��zI�@i=�`�w˞d�p�8�v^�sw��{��_���:�������� ����@8�Y��u�j����&4�O4�!y ��Є�q�&)xU���O{b]�����d�W/v�!bA���C�86Zd��z�Y(�6)�]^�xPة��ݮ�߆9����
&\�����V��y5y5�ڣ�t������[[_�W�Na��tB���>�!��["��Ԇ�5� �޲TK0~�b�\$�C正l��"B��F�T��9�ݻ*�I��;��R��:�
���Ov=Ш\pq��n��}H��aA���Ug��
b�z�	kwYM	���A��*g�k4�P��q�۪�M�t8�f!rm&#}���y;���W9>^`w�ō����k���zvX��gb��Ed�yt�����&
��AJ�����y{�ڎJHz����~�f7 �'J�������M]7�o>�A���;:"�0~�2]Wx��(�".�a�,幺g����!�(y[�tㆽg�qi� � �����!ܘ�e�E��*�~����N&�9n��M(�t/ԝ�l�(�gY� `8џi�9�1*�ͬʛ�?�۱4����*��=qu�m�iHo��Tö�&�>���	W^7��B��4>��V��&O�B0�ZN8'Z�`���1��5���[�}���r�������u��f���@�%^P5�]zm���h-��%B�H��+�^t�r��յ�r\�Y��	8TFp�o42�Q/2��E�������[=}��ə���+N*�B�D_8���kي6;a�o�P]o���{��L�u���^�i��	3M:nÏ�ձ�E��+z���V0j�ԯR�Ng�J�LǥA�����is,y��'
�pv����|��v)��_k^:�x�s�|����tj��o<�^>�����YZo(��F��n��sރ��3�zm�B��b���C���<��5�8�$�b��O�ѝ}��Q���\�D��������/�3򭲚bqJPQ)SB~��R��CՆ����]z
��x���m$��H
c���������6�8T�w�eϐ��U]�L�V�6��і�S���Fz{蝁_�ѐ�\���:��H�:��p!Q"�vLv~��z��;œ,X��L�c�x���踲�S�g�RukK�ڝ�D�+�C�k[��mG����8�u��O�sta�#�-�Ы���,x.�Ͷ�����J�!rJ쌞^�Sҕ�||+`�qq
G��Ӥ0%�>e�:�)���h�	ֻ��"��Oc�����K+�d��K`|t$�fM�DR�m0��_KR�CY_���E�v�>��T��c�O�ؿ�H>yVF<�SV��x�;��,]l�y��;!"��b�枬Â�Y�U��xK�3����n�@�����]!a�EKg�V�}�=|���1�Q��MMڰO|�%�c�Qu�*=e���p�]�9�(�3,١(	���Qhߗ�$!rB��4��h ��"[��$\��d��Q־`��h^�D]�'��<8�Su�%Ԕa���*Ӥ�l�1���a�j^~��Iea��N�Ip��n:�;�,�=�)�i%-h����$�DԿE��s)�(02dG�rIE�Y0esr�?���aYJ� �7B��<ʇ/��w�#�gm_���D�m8*�L|m�E�H��'@�R�;~D=��B�/!��z���pǗA �Ьf[o�61!��&��.� �����b8ݘN�,K�y܈IPJ~ 0��
\��!�4��խ���tO!�SO�x���'�� ;ǐ:�R�ߕ�~�C���.�;2>=
(t!o�ۚU��\V;�˰ "+�D��^µս��v�.�^@X��m����]d4��OP�^d�rw#U�ޡ�^���A�\I�������78����<8=���&�|3]R��Ј �O��]b!L
Oj�Md�OK��T�xZ��>�� L5���9_�5�B �ѭ@՜y���

9ɒXGQՖdT�	M���`�	PϵZ��ht�w�?��ֱ'؜]��Y�Rd��U��N�;����d�����H���|5�Tq%�o��kC����H���\x��M���.�J��h(�6�_��Va'�'�Q�"sS���7�YCI��mӟ�CP��P��C4�;�N�A}�H�����m�q y��f�P��mg	���i潬\6y��>�Z�� K(�n�'�Q��o����O���յ�j<��S0h�����l������=F�XĹo��[�M���K2���8�xMV����c�H<����+UЋ�g���>ߴ`v�fppp2+h�8Z�'xE;[�]̜�2�f��C,q�=(����>?}6���*�W�V�L���	D
��O����I
�q����*�k��"j��e�/Y�����|�_�sx�����1�b ���X?�D�D�pv
	]8u��h�X�7	��3NogUM�!ˎNI�fЊ�T��	B�`�&c���L���EHh�$-8�+Ak@$f��7��8y8����f�x��<�'S��}�,�ty.���y�ݏ��r�6�A���]�&�t}�HrE��.ׁ`��D0��{{p[4Hϓ��<����N�������ہ��	�����$5�1E��R�Q��TA��J4�
͐�E�f�ī{�c�B�P��H�q1�� ܵ-�(J����L���f�{!��T.�S�N�<�RyA�_�Tx.��I�B��ONL L?�/�*��}<���D16 �Ȳ{�v!��o7���̄2ֿ�pi��mG���&��}ʁa�|	��=
L��TӔ?'���I�U]���U�����q��t톥��YB%��7H���*�8�z`h����ɡ �(Yi�7*��G&Yz_CƤ�+�l��2
�\��O�V2"ɚ���˒ћ�EM'%��C`E��Wj`����L�t�p�s��!`�����ɩ#l�w����>�U�J��`��ul�ܯ�߹��4��N��f����Q���*�d�;y(�lզ]�e�l
�Q�*"�\�=����k�S1������_V�� kG^�K���=ª��AhU{��U���[�/���S��@e�x*��Pe�~�^REl�9:J��<7���]���4@@���F�淋h�c��n

YoP-��:�b�=�u
�_�Dćʗ!���0�q��v�(9]��u�t�8����p!���#�,��3嘄[P���/���.�r��LdQ1�S �o��+(�oz�8��w9���&�UC�X��}�q'j��mo�D󽽟�<�yoa���b�L����0�%�	2E���E������iH�G1���$a���^Vp&���� �y��sT]Q1\�i��i�}~�Qr"ZCl�E�TM��p)��`)���+K9�f�^D�8zC�����
ԃ�ˍ���;�=���2_ǆT�Œ�5#Z�w���r�E/�\6����D�>y�:!�0- �kI���j�̘�� ��TՈ_����$^�g4���Jw���"@��ؕ!����zYJ{*����іU���1��$գ�߹��e@�(�Ӑ �&Z�.���`fn]�oܕK�#�q��X�L��y�`-�aCyx��/�Eӌ�h4����o
`��sӸ.�m`Ǎ�~S
u�C�@�8[B)�aq�K�a��� ��ǅ��w!�,�M-��YAb���VE?�6�_�6S������|��@�\��$O]� L���g�x/�"0-D�}y������W�~�j.^q��4-%+1�r^�6����7w�'���P,�y-�ăF��"B��k[q�hݐqa��
��m2w�h���~ 65��x>�Ld�2g"�V4o!c�i|��-AdP�*zw�5��顝B�r���;v��c�=;���F�'�Z�(uc����ƒ��x�zs,c��wC�X$s��W�y�ĵ���M�
��7cT�]���z���&:6
U~�,���1�).����;*v�(vtW;e����+St�V��᳕�7��w���wuW��V���	�T���XE�4wU'�%�]St�����BnB`�H%��~�~���S>�ǧ�,�ksZ �P�2����V�����q6�%(xbR��UX���tg��{gn#>�Q^%�b�3��<�R��tQ����u�fq�f��v.c��mIj��1��g���Ev�`{�x��V]�-��x�!g�=Ձ2{�VC�#���^�ӣ��j{�KNl�8\�g���z�{y��r7���s#y����"V�i��1�M'�p�*Ԕ7����mD�B���D������T�jra6�?�a|K
wV���Y�YD�gm	�~_�G�"ε'&��^��c�n��;u��%��Zi^v���B�5C�%^�2Yx��Ne�΀h�.{�i�D��0�P!�����Ldq�$��s�Iʟ'���=�vA4K��m3KdQ�m��/�P�FtW�>r��?81z�2ZM�sF��j����n`�c��1������ò8��K�bc孢
f�8]��,���j?����Zw�z�oshp�a����\
�A <&�%$O١PM�'��d{F����/A&hՁ\wa��8Y7��dSsG���F�w�f�g�!FI��{d.��K�ce��_RNO` �5�J��-~wR�&��\�W�9c׍.D
�
��[ꤴ�U��Z���W�;�ȝPx5-������a�a\E�����Il0�{y�%�E�����5��ȇ�y�4�Hc-	�����VdU�J�(�S�ZY��ߒIC�����[:��8����րxH[�����j 4��j��-�I�-������@h�[b ���u�,�G��ѳ\���#,�V{Pּ$�h2\c�Lk�
1N_�e�� �X#4Yk���<5�ј���VQI�l��
E��52r'/Sk�8��U���߁!�0��$�tc7���0!��	d�dm���^�/��$`� �ȕYg�����d2��
uW+:��'b��H"k�JCޤ
��a%�_<����p@`AG���m�C˟
� �L�qe�k]���x"rC����2�q�j��;�Ƃ+�a�#BR<�;Q�N����~`vXQ�ӂ}���7ª?��.�C���)\l��~\uQh%s�K/�J �L�5�'yi���ƖQ0�RD)�Lh�޽�޺-��}�v�ͺ��.j�����H e�8U�U��'�����h�T^�+��27��K|4�*��E-��XqW
��^�mv����bg�SsΚ�N՗$.R���S�F	�q�_��4��*��5g�7�o�XO�������7p��S��s� [��ŕl�v��54�+3�v|��v9��T0����8Ͽ��	�� (�ؚ
�;��+�p6/��/o���׶P��)���o���l<������y]�j��m�u\�j���[�[�ܜ�^y�BC�lFG;��
1�����q��t�P}Q��d@h0W�g�I�@��vY+��=<������"��C��a(���Q�j���x���;��~(v���
 �Ɋwm��*��PfVh�� �4�p��zI���]P��+��5,bk��{�.�
,[DE%]l|��@���"˗�|	�:�>+
�tEI��;fG�l��\`6PBu	8z+Y�b�bzZ�j���1Dq�b��?^8�XIg���u1=�{�L��Q��5@E�1���x����P��pO�@��IQ�?�����q ���|# �JI�jF:���w#��,�=cI������)��h!
5k6*�e�y�,�|���٪���1�lΜR���G���q���!:�����e����v*~���(Yan~�?��� �v֥ȿ�q.6D�lB3����k�~(d+2U�?~�H�|Tt�Y��[�-�v��@�<ӎp?�H�6<�_m�������6?�)��*�3R��=#W�UA���bOJ��5��˲�����1ο�8Yjz���8[͗��o����y���_r�CO��BO�l�������'ޅtD�܄���@�k�0kM�5p����q�έv����-���78�HwU�#����揾����ʹ_�ˮc:eO[<)�����#�W�?DH���D��t��-k#��6���Qsܶ�>r�#3�"��^�(^H�c�~��?[d����
�?��1����[�m8<7��s\S�vo�kb�pW���Z�%Ʀ�|4��I�$+�Q�a�O�OTeZ�2��ᄂnε8���2
v��dg��6���n_�25����c�-|�m���(���(p��pN�PZ�RT��Z��P� �����4��C��W rG�t�\y�aH��Z�tDp4Isr!S����h#�����q�tp$8
��C#ŗl��n�		��x>QtrAݛm3`�I�f�2����/G�"V<)�U�7kf�V�QM�����A�b���a�৑싑Ng���&lko��v(���,�$pC(�/�8��<�3� [+R��ٹ�:;r��p^V]!��B[��H���b���h�� q����1;�����V��
�	e/K��A%⎤n#ȁ�4���L�������ZЏXʧ��D�4���8��YQ�W�	?��͒���7��އ��e�ͯ�%�&�J<��w[u��=�aX4�&5:	,׏� ��F�x(/�֖�<@�<u��u��S÷X�ռ�n���:k�p-��!������֕IK�`��lJ;K��CA���\��)3�k���j�Mz�A֓R��u!4˃�!�Q3CC*�D���"Vn���:4���]|��"���Ri�6H���MU���ڻ�"��¯��pE�S*mpð�c��(\��_���Ɲkxk�~8�@�n�ֈ�Q�k)a�+4A��	I�j�� ��
�ʸ��ؖ���A��"�Qx�w�!j���d3�
u�B�5�s�pBp�W��t߻f\��o��a(dV�i:��H�����_�l~m���0����P�Փ�m�2|��
uYp
i�07���xϷy
P
p*�G��tRA�ק٘<C��,�.�E��Q�}8��zNn���+=M�gJ��r�/����&7��������(P�Ἄ�Ǝp�?7��2��a�v+6%h�`
T?���rK�Z��*��i�	��#���G���d�������8£�/U�$�X��J����3�s�\�8���~��M�C�#�^����=
s �H
�1��&2�
�F� �w�zk�;�*�_�Y-\)G�����b('��[�[�h��M��i�2�^�����hޘ��ٹR;3�v���j�S�pe��Lj�)�<T��U�+�d����֏£c왂�Z*^�W5�X�]äC�Dr���}<��N��㜀��"sE2d�j����i{���I<@�}�	��[5��R�@�hEYJF[��#�����k�����C� bD������@���N��ᕩ"<�̳ebh�~L [v��[׼�$N]��4.Dd�A3x��=2�Ed����+��|�q*c�}��I���)�w���L�O(1#����=���B���~���`�����M<�e�Sɫx���q�ͷ�s�y��-���m
#Q+���t�S��Zf�ǅ��y �9-jz���p����10�1�V�gj[ڔ	�0�x�U�	Z1��TXʔp�ƸΑBċ	C��d���0p8�����
���m���
�p��,p���m��h~S-�-��;�<ӏ?&F3�(-��9h�p�I�ϛO� �Ψ��:$ix����r�����$���(>��k��N��K���+���{� K$�=�ܢY0�)V����aBe�/!�3*��9�$`�)�}�{Lь�x�ĕ�j�h�û��Ot�MK'c�ԉ�^����q �3�I��-5�,�ˬ��7�4����݉n�f
���-�wP%W�_@��ߟ������o�J� t�� ː�LZt��'��/�|�8ߪϦN���ɥ�`�:��H��U	�+���t>EƧ�k�Ne��!É�15��P�8�5 2�3�
N� �i� ��A=���� 0�M
:SS�^�b�K�q�9� #v�Y�C��V�MV�]�A���+���k�yoq���#�����M|���=���<�z�cu�RW�i��� m�V�S�����'ꪖG�|/
��M"�wC��;��e|�i�6j�pprQ_+]\ ��3t�Պ�9�{A1~NŁ��G���
������!�U�e�Ƞ��&i�ݘ��!��4[-�R� �T��Vk`qi�Q�Ɠ�rTXj��}�'SZwx� 	�������5S�#a����	آ ��;�H��dc_)!���+0A�����ܑF�7hDyů�z��]	�D��
����=wE[?y����Ɗ�
C0Au��ܺ�Х���T[wq�	�g.���3�jc����xm����e�qy
��d(I<PvED��6�äj�| 7� ��x?��oXa;���VhjK�ǳ$�ķJ֣��3W��`AD�kt� ��'D�r 
˱��7-�C(@�ԗN⊘�P�m�ʫ������l�Z���M�R�o"����5��� ��Gι2�����`��;N��l��� �o�k�!�5u�]�y<�(vC̼����7�&fw��2��0�bϡT���J�)Ƣr$��_/�q%˳$�G�xyLeߎ:Υ�����f�:�۞uGu<N�H��w�>��g����"�>��,^DXC��S��H�K\�������X�P�с���-�U��2����7�W1�R�+*:�o���(d��x�/�4�\�����2kA�Z)��;Hc�/=.uepf�6`��섩��*J|�:GZpa�	/b�
�~G�M|��z����ރ�l:����L'���\�B�d��Ƙ��y���o�_����%�+ޙn����eh.�v�L�<�@`�;�ʨJ�|Jgq>'�\�p�t�i?�ӽ���1h`}����JD?�R�UBk�'#^T���.N��y��\Ymا�D՘�� =�/V����3,�4J��:P1kA!��fhU^�˩GΌx(���4�
k;������*u�y����u3���^;�J]��8W�/�i0*E�
	�񀤌�}WX���Ψ�q8�J�� �A�r������sG���_a�"釈�fx� �V?Zp�wKW���Zq4MA,���@4d���%���!S�����g��_�Q�bDc��]�/�}?\�_:-���]*�l�;����Y2�]\\̎�i�jٽ4ڌ�g3���r��������	ă�d4z�������;�_~���PK    �{?l��%c  �*     lib/Math/Cephes.pm�Zms�H�~E�î!� ��-rqv������n�r)J#!K�6��߯_F�=�]�R?����t����q�X���Ǡ��8����ߥ���S��F9�Ql�&�!X�EPD&��5Llb���c����ki`������E��*��Yd
����n���ǧ'�v�����rx�|�n/~�����^��٫U�Yܦˬ�Y��,Z�-��ߖ��}�*��u|Xc*A����n�Q�f���F�e�6齶�-�-���,���"�j�gǀ��]������/���������?8���O����ɧ��'O ��=������_���_N&�Gw��!3��'΄ ��
o���HF�Y��Q�]&�؈�h�u�|����eQA[��M
�Ԏw�g.�lث�)q��C&�
. �O�̈eF�̈eF�̈eF�̈e|���]2Jg�
�b�y����"� z�슓���H�߁�}��!����|�t>�>��s�SO�ԕOg|�p�������%9c�:m�x&)B���	�AK��k��PF��-�(%̓�C��C=퇒�CO�˜O�Ԟ����	�n<ADɼ��͠c/�!�B���� CvU%Q=t*�L�(&zWM��&�����v'�	�wU���\	�EJ	��:���:\��������\����B`�1T
�^Pi#��#�b����n;+of}�Ey����r�˗��Z�ݥV�ŷIs[4}��b���R}P�A���q�N����Wބ��-˳\�@�YN����kj�Z���4���e�&G��Y�)}�=I~�|��Y	rA$�G�Ja@��L a�2��o��)�1F�	PNIZ
��(����r���բ'&���&����@g9�/�>�17 �ٽCVcʘ��mÎ�������1v	;6��c�.�#o�mÎ�����{t�X��Q�[(���Ŝ:mU(-��D�	��4W�� ����D�#Ğ+ݐ+񲵾�tr�ՈB@R�6��w�`����wpq���_9Uw��{�\�1�z� b�o�����G]�8;VгcFN�ƓX�W:�
Q���C��?��G��O
�,���EM�a�Y�r��7�*d�_;>d@���` �'��p88y?��PK    �{?!D  _     lib/Math/Cephes/Matrix.pm�XmO�F��ň���#T���BIB>��QDE�hI6�`o�_x)��ޙ]��NL8Ej?`����y��yv�O�'8l���'[>��h�C���,X�flxî8���T�fS9�Vq��u��;Fp{��w�O�{���/`�u{���V]�
�m���i�е6��^a��I�6�jеrav)l�b
�C�`��y��J.t>O��K��,��{�|��u�YV1���U&;�c���nUm�,�Ж:}��9�<��%QQ2���0b1��4�x�!�T�:$���I㠋̃�MU�q��猈Vљ ��a:V/��Zr�u9=+QI��*�^��gC�@6�.��Uf���!`�>�f� gy2a�n��,�!�  �.�m�B��3�H��)s�KS>�=2o�ȊL(݁ͽ'1�J��V��: O�
|����r���W�E�R��$�����E�DoL
1�T��.��l��"�Dh��Q~Hs"����/(�ݖ˫�f
�F�&*9�&�[�dR�IW��.�
����4,%aʨ6J"�IW;/\)�J�T���cNʖ�X�aI�.����P���Ю����0L�i��g��WŞ��aɢ&sb5�;ϯɋ��!n��^��d.�*2��ly�<+���瓯��K�$4��� �+Sw�凫�Ͼ��X��)�X-�w�Yc�֧t�L�\�[���z_f�ΗB��U��t�1׍l�k۔Q*)�>�i��lr��rN�F3ߋak�
f:�r�E�kj:Xz�Y�P'c����m�CA�4Ct?�_�J�_/���k�Hk��Aj]b�V�8��FJq`(^��+�sW��z��|�t�+3w�O�����Ȼ{kȍ]��]�ܣ����d6�5A:�S�ܻ�"�/|Qu�+�W����Ϥ^o��J�g�/���7���MR��ƅ�i~OQɔ�S��0������YU�ͶkY�A���``Y��o�;;�X�?PK    �{?�a�x�  �f     lib/Number/Format.pm�<i[G�����D�-t�'��`�	o@x�d�'$z�%M��s�M~�[U}�!���
F �N��p���C����v��ٳ��$��!����xq臓	�y�~]]]�?��n��X����s�ۻ��_įW��ᦡ�6��(����/�N���/^���?0����������/�?r���bN@��az��]�GY8bY���p�?�_���[���9�?:�;�;=�gk�<�8��9��ck�g����e�NN����~����������דק�l
L�+Ә��K0�c�{>²�� ����&�%�'ӔEc�	���.��Q�\L�ӕ�zE	 ��C>�I��d��A�$�n�$�q�
��]lȢY��)�m�m�^�nH��C��(l�R����!�S����2j][���L��4�"B��}y?�rq(h��d�9���t����x�l�/)�Q�t�����2���ۺ|o�;��O� ��'�Y�
��K@�� $�x��Z���Z��gEX˟-��~����|�Ѭ��B��`-'���2��e�m�{�?1���	�hf�rQ�mn�_�){�c�W��M��Bn�'T���"��3/L�$�����1>� a� }b� ������)fs��'m��;�a�
S���_����	�_�̺� ��Y���?:��`hg�P�q�Sz�k�R'~��_F�:Y ���8�w��0�C�LyL�Fl�Av���� 
� �a�=,�P��C[פ��#-��zY�;�?RE!��p�O2!o����d�c0�cP+�1{�hv�Y)� gt��DW�a�^Y�݁�Ӟҳ�$�2KX�D*����`��������/�ă�zB�a!�\1O ,rp,l�K1��8���q��,�!��V���������-��A�[�tCq��l�O�Nꬃ}���{�cv����0���5v��u�"8��r��Ed8��k�2Wh�@ a��H�g7�o�-uB�VI�
�����"'�L���y�!��d
�Ē�v�������?��P��4���Q\b=O�w�:����Ea"�.r�>������WS���q6�9�G���kg�P���5��l
�
ZNCfYB����_E��vL����������ܡ��Hfأm���`�6�����2!}����qbk����((�VO��x:�j#��<o%��DĖ�bi��Px��-�/o���� ��DO9�6ow�'i�V�@f�&<��4h2bV�55�r�@ƍ;��?bԣ����_7�5�8�3���J�C�&W�,D\3�������	�åC
>
)���v�ar�H��ȶ�+a�g�F�C�)���Sa _��>�|$�h�E���/�Q0��
"�{T������Ri����P�N�
��[���8�W��ƀ�N0��uѭY+7er+�yWIC"����h�
C���t=���B栴���/�1�>X/y�k���K��yȐ�6��E�WN/�GQ�֝�uȱD�6H=rmJ�����Ta=���6Vܨ�4��"u�	h]2���A�TX����ybD��&'����u�h����r���i�7~{�����is��w̫�M�S�.FhT�Q�2B���L�A)���sa+��uK��LE�L*W������3����}*�w�Roz?J��As<x��Nd��^��'�'	,I�m���U�ei4�&>W�`�a���#�*����*���9�Ѷ�3��VlH�Bj2L�� J<�K�Q�
{l8�bo�b���N�ۡ�46�p�N�mͧ=^���߃(�G������zA��\߃�SjȺ��T%��"��-�
�K��͊]��o�B$��ր@�

�fws�P��0c��a�anX�|ش�
�����6�#�P-� ��)ocW+��Ϙ}PMC0�Z�[���,�^�Ö@�̉a���U�e�d�G*�+��cZ>F_���?�M�S�%EԐN5�^�7�@;��hH"J��j�;�Hs-�Ul�1
�T��~�l]�'�H��iey�����<-���b�B�:A�2 F�d*���└*d��sN�����[��6O����3\�G�G��y��m�a���o��K�b�hY�m44��j[K��(	��Z���1%ټ�w��Y�'��۽���[u6����\fs&P/
��=Q�f�@�`���{�jM�Ǯi��5��&�V�}E㧔p�[
`$���_��{���+�nR|:��*��&>P��p|�k;e�* �e-�yt�E�
!
>D�Ⱥ=G[�f'���mc�,^j�|[3XWMs����0�Htqf������%1��>g����ik�,r˙�9�P?�̝yぉ�̜)ݲ�Kܤ�Σ�]��*�"�r�n���lI*�~�e�XM��|��6�3K���������k�B.��]'�K>r��hN�e+r_u��=��=��x���U���as�S��<�R� �P�1����uD.8� ��9$Er��x�Utv�n#�J_��unZ���`���Y�W�m���'���N����=6Ψ��{	7��Ћ�f3gK1�Z���a��k�|d�o4i�a-	o��7x����C�]g���mZ#�ǂ�T��m��r��՝\?���YWvAI��4���TUӗ�1�H�`�x�|Ҫ�̢��+�5ȀF>>���9l���`?����۱���N�}>l|��n�h�Z��yѪ�ie��c�\��2�_Y����,�*7ƈ���}DC���m�0D��s�V�<lH&~�ś�h؟Ű>s�|(�gZ��@�)#�ؾ�@ܠ�1���u�^"�ne�;����i�>H�>� ي�n��H�%Ѩ�}��Su�^W\�g����X���
	޲�,�5�O��wt�)a�뤀�������!�ݐ���5�i�n��)��G+�f&����ц+R&o{GC��Z���tkSZh�Cqt+z��I�D�WǍXJ��i�	ϙ(��n�`l���`Dh�i��?86TǪ3��m��%��$�
'*��8��Yj�~R�K8?C��1#|����'�L�:]Gܺ�b����i�콤r�xl�sw����q6׮�(���Yu���a��ϥ�g���a������.�~}��H��ygPh��M����B��l֜�I���r���X���L��{�%i��^ �t���nG�
��VQ2��SX���b�h�E�Σ�OV^U0�p�`u���8�1� J
ѣ��1�(�'����6-�ѳ�y�u���Q�kE��|�d��^���b=��^q�S`�Ӛ7|ѳN�ľ�VY+w��+VLh���3��1�/��Mx�&����В��3�n!Z�e�e�b{���CC����b���7�y�qX/�2��8���v�"�@K]�蜘�܇w���x��5ݫ�i��Ӯ�q=-���_K����}YA�6_"�'���%��X��	�8qMr=�.B�
����|��-�t$@�e��q��8ao^?�"M7�uCT�8{
�T8P�5JS�y����P_r��E<D!���I�)�jꨀ�Z��5=-ٗ/�s	�0�'�~C��Ò�h�t�hr/8�]� K���(��`�	QT��ـ��Q�Y�G�I������� �	�\"�z0dM�{��� �n�`�CΉ�Yk�\����^x���W�����0�8�r�����$$iv�0S&Q��nȚ������X���,J���W�ϏޞvX�ٱFb�r  a�m�f,�#��4Q��

�L�k'nc�9H��Ɔ��6�]�@^��9�5���l���:|y�"��SH@���l��,K9��v���F�mx���	�h\L'�������$
��ӗ/�Z(�� ���}�Q<ʠ�,φ��|��Ş3���j��4R���|\�#��?ع����b��8���Gz�h>9p�Fi�bk���������|����4(�c��q���굿��^N��&�O�@�$>x�q��6�l;�!���8�����yЦ�c:���%����~��⭥לǋ1sI��P��}D���g�4�_\�`�ˀ�4֬V�%	kϪ����	tf-ޖ_�_C.
~�o���v-���Aa�
��[Q��o����^�w~ɼQ�P�]���4��D�;��~�_�����@��lm� ��|OT�P�
�v��"
�jDK�|%%��:|Z6�Zv��l��<A�|�]�8�=���L�7�( ��,رRJ��R{3z1��)��p�P!@�ee���,F(P��y^��3�|�B��[p@3�Hg� dּ�4��,*�Y"�:c�$���	;Y
�U�lM��>�X�+��¾XFqr!�a�#��6`pix�5:|���`��. �� p*Re)���[�g���J�	x��IyQ}�v�~qk�W �!7��NC�k`�^���^�p��+X%��w�r��t�\$�"i`���T ���.��:l��o����X�KΕ4�q~�g�CQg����3@��LH}@�"?��3�YdTpH�S��-�����Q֎h�\6R�u��s��"��v�xe�9\a>�+Se ���4�]���ߑж�1%��-U#]��� A��Xy��ͦ���&F��f�z֡Ƨk��j���k}b�˷?���{��L���`��iK����Y*�Y>yq�z4i7����x;'�c4�L��B�-�,��"���EN0�A���.K�C�}"��f�ڛix
��g���~_�Nѥ�B�r������8C����ž�&[�|{r�����}�����u�p`��E�#A�y�v�c�t����Z](wR�{�]�Jm�6C�o�����i�E������J��f���$;�ǜ\TP3�|R0s011н����Jk����vXi�����|La�3��
�y����!��r���0%�]�
��������l�гl
S	���}����s>�GƖ�X�Jo�;��ET�Ev���<�g`�3�0����fq�me�H�}&�
V#!��DX�G �V��f}G$�j�o��Ʊ4ܖ-P���<}�+�h�b���O�U�z4	.��%��6p�%���,1u4(p&�������h�lI���Fu%H�&>S�
BL��_�s魏�!J�����0� G-�#Y���6���$������)�⛝(OOE��Ǩ֤SW��)�`���0 ��'t�ږ��
�p!e+@;z�KkjGO�U�
�'jwAnuoA��j��K9�3e��׎..���*]�gw
+Z��l
(��_��o6�74L�Ϸ��}��zL�k"�,�c�eK�+.؄i���V9��&'�lVT1��c����@��|�>���X?��@�s�L�<aψ4�E� S�y0� �Qs���|ʜEQ�У���4�t��و��
��,���J�Ep�$�8A�C0>�
Ɯ��%�W?��0o�N��	Չ�]��<B�$T"a{�n�0�a�x,��+RXT�fyaZW>�4�3�D���#YKV�L��+��װ������?����*S�fvw*uZ#�U�+����Љ3+ͧ*���5DZ���R��&�r���s�C5yT��@P�zi�UX� �s���Z���atR�{�P�~>A펋�\����r�$�ȣu���aVjd���������ֲ]���z<�H��jIF[E�D�y��L�J��	�䈔0J/bT.�H@=�"1.c�Ed� �W�t��	9���x~�~�r��L���ʳ�iW4��S���DY��ZYS�}�2f��=�~�!�
v<����|:#P�b����qw�G�r�8w��Phvr���Gє;j¿�/Lt/�1Z}�\	�Y���b�f+��ѶuA����t6�������s�YH�`S�|j�	�����79�r�q�h�j&�)9�����'��TA�������Am�B�Os��P�(�0qK�+i������/`e��ZX�o��Tǿcw�QI���|�H���2�h+>���IGZ�jC^��BI
e���AE��Fe�I����
j�6�J�.�E�|m5�:��� �^`�N҄b�"����	<g�v�
��t
z,�U�"%,��yjhi��*P�n�N(����u�t]K3�u�����/����u��V�,��+�t��ߝ�q����E��S�ゔ����y�����]�l�X�\�S���ҍ�A9���"H��w#p����N�l�nΠ��ʉ���@�mcົ4����<��#���D�S㿷>����BØ�,|v|r�����O����2<�>Ϣ�f��8蹏�0���/x�A��+��?Q��FK�t���;dЂ�T�����]8���_z��u��_�
����}�f�����Z���:�|u���j�jQv]��V��a������,~��Y2:�r��6�c/VGa��둭,$t ����#vD�j��`iF8落�[g�&�<��f�* S�ܼG�80'����ԞS��"
R�I�F����5
��|�>ܵ�Zw�V�^��P� ���ݎ�Y��� a�"��T�|�&jN��ď�&�l��Yl��Q���_�6i��_y�F}&�34^��tě�ȑ��������vE���F�.$
��<��ڞraCE%���t9h�4����5�V) /~|��θ�(���(O�ӣ�o�u����'�^l�Wd2�R_J��eK�\�:�!�k���m���<r�w��ٹ��)B6l���=|(�_��Fe�񶁏�Y��@��+fʇ�������vo�ؠ���qQ̠�b�𰲗f�=��{gW�`^��,��ao�u�׺�}p�3.�P�e�18��g�C��]�n�.啉C�k^�y��_C�ii��eѵ/�P�@J�6�Jq�����B@Ľ����<0'�Mt�����	��y�Oqj�G�
��vQ~��\�1�VǊs�.Rgp?_��`}}Z�PZ��^hH���ex�jg���
4�nB��nنJw�̸��6a����t���V�7�X�����7y��*
	R��"��k4Ӗ,F�&c��Ċi�/��I��{`�!���h�9�P�e]�Y�MZ�O�w�۞�(Ã����_�(��ȃ\%�'���������������[�4l��Ư��������R%qO��\��op2���Sֻ|�
*܆}�h?�2��+�|���ˮ63c�A!��Kd��7�ߦ�Q#�a_����:�x,u��	�O.;�	w�Z�K$P\�E�Q]n��i-�m����)���({��V�pt�-�S��(�P���r&j��A�A����Η�/b���Q�X��(L��U���3d��7�]I��P^?�
��a�����Y�J-|��G�K�\��	���ź�	�D�d��+�"���I|û�a�ԝj�ҨROv��|/w(˿��G�*�N���W��^|��P<j"T�%�p,�!)�5�Z�m놄^��ʶZ *��T�tM:�	\ɨ�Y_�<c

Ϟ#�5b�,H!�6��P$X���n�▸��;o�t5a ˎ���������7H��[
�����Z�ʯ�
h��W�i�?!�&3M/������Ǎ��F�m��E���Ef�p�KK����p:�Ǟ�MǊ?�\��˗݃ipu���

���cn@���U=��&�9{z�{���,��'���󴚧�j�����l{6}��,���a>�ף?}�OU"�l��>���c5/��\>\�e��g�|�6.g��e4*����SW~y��e:?�~[L�i��yTQi�"-�J��r��OU��x~���yB��0����Cx*�Xj�U���8������?eE�d�d�/�ä�-|�T�2��Ӌ$����<�^�8�b*��1Ms��E\�X7�����?��߫��Xtv�w���7hu�zj~���C�f��I��<�׷�,���Jl��b^���t���ޏ����}�L".���.�[�$���|5̒���mO6ҕ��d�(s������Y���z�?Y��z�u���qt:�����`�ch��g�t$6 �Ӹ23��}r�B�>Axm��4�U��w�;͓?��ʋ����7"y/:}��.�CП��4KDTk$�G���5U\Z��F���IX�����~Q�Kh�a���Ȳ�	��H��Ӹ|7�-ʳ�mS�� h�i��zͥPK�!�I���g/^<��3w�1��?�-�U��#�dbU��y늯%2�z��W��"*)������c:�y^��-����&E)�Gt�^�k��_��.ϒ7��H�B���/n�=�H�i�2��
o1x�p���%��F����q�%���,�ڋ�
�p�(�'Iy5?ɠ�ת{a1��CN�'���ǀ�j^�/w���UAC�Ⱥf���j��w�U�t�+�tI9�e	l�1�pO�t���^��|��������h��0�HO�x~8%wQO<�˳
	��@Sy.U
$G��h��@� �KIx���<�i%x� �|�er1I�5���K÷�h�%H���9���2�%|U�����Ğ�e�Ng ~"��#g� ��Y����FA: 5�(_O�>��?#([�]6}õ�o�5֛V��M��Fo�N��>4������O�$!�����{�H���>��j��E2@����g��r5l�Z� �� ���6n�#C�2C��	��.����	�-6B��N�.0p�.��"���p����5�0�^2KVP4N��5W4�߇�x�U�O�|bC$��O:�T�B���� �L;EHuaA"��n+���5��(�mn���A�ka G=3Y�#��ͭ�����ۓ�;��6:������Q����(R�1)��̞i˻K�S$+ʽ:*JdŃy�T ��1��ԾH/:��w�z�Q�F���湻W�8��A�>�:���ϲ �Z�ȟ�e�Hxv|��Ц��܏��a�؋�� ����AdF�� � ����4	M�Eh�Z'�E��G����W��|�9���lB�iVD~�w?
jO�8m��#����+�筭� ��ٻV�����W͜�ݻ���d�y�}����#���I��'����t�!?���R�fz3&����Ǜ#$Dի^�\\o��kT��mu=N�q\���Pc��݀|�Q.���ȡ��j
dgd�(�J!���z�NA>��R�I�����ƅ��¯e|���=ITU���~�tn������2pQSt�����l!��d7�-CU@F�l#?z�7����E<�����O��y#=������
W�Y��� 8��S����Y2��m�d�ǡH[v��U����|1Š��<�h�H��o��V5�� �AlN�tX�6WﷵMB��{���p���;M�.a9�e��t�����zZA�k[ ����-
����B�\4]�Ƣ���Fʧ��!T1M�>��ۄ�{2P�$GJlFf��)A߱�V�´�����8j���};С1M���-� �D%敏q��
�o\�0kZ�1`>6[M*�����k��X��9�S�[�I��P�5�Ȏij%D(���s1ă��f� �����������i�ox`�.�;"^q>�
��_;� JP�2K�3���"�@y%8K1�R@��l��<��;�-$W��>Z���d�0Ӈ�Y!2�ǘ���\dEae<R��ǊD�O���ږ�k��
�7޶	o9y��:�z��!K�`�	���
ڃB�OO(A���8��-�Ț��:��*��X󻖌fa��j|@
 �!6����7뀄�ٟu��x��zj_+�
|'��f��x�11'�-x�'<��a�����/Fv����Ȼ=�� k�C	$��C�m�wK��5����ਬ���I;H�'��� d	;c4]f<
}�w�f�7�v��g�d��\��0�F{�mu�.�	�j%��E28�LQ�Z䮳N5�m�{B�v��\��P��BN���#O/.ZPL�قf�H-�]lz9�dr�q=d�
q���"u�6/.B��P�i��
�W��8��ّ�����2�2��.�bL����m�d{oWD �]��	'J�G��J<H3���i�)tur�[��xMNj�9���U���2٬(� JX�G��O/;�>�S��][Z��b��6U|�}�%���/�T\�6����V�V����⏽7��H�;���F�sE��cU��`���#]�F�4�
�~���+�C J�3T��m���v�o�.VS��:eU-wk�;=��M�s�o�K����Q��LPK=�����	�^�/gsS�,ōi��29ʎ66���ڌ�N!(�\ͰƤ�t�h��<꿜'Ifή7a�:q�5�xK/ȋ"��i0��p�]% ����9�H�3Q(Ͱp\S��2ͮh/W	0�}+���`���<�n�1��3��N��@9��(�KY����)fۓ���U*�T�#k~]5�i��%n:B��Z�U(�>�*���n����x��e�t^��t^^B(�����2����v䧮��K��hC�Aى�����QA���Ǝ�ʶ��R��J�Wʦ�;D�z�M�B�I�k
��5I�FقnX��i�P���.92U� ���e{�ΏH伍��YJ�����
ePK[&Y��X8��y
�J��1��2�{���V8�t��0��7@�T��?�it�L���h��/!�v�����F8J�fK��wv����˘�aX�����c���Y��3A�H��e�1!�J�02C��h�M��jT��ŵJ`g��T_&�I,�5�����x������T���R{B�J>cͪ��[�sZh��A-M�"�k�6V{��/M���/A|��o̍7Z2����ƅ�/�x�
�EYxWb4{�hL��\�^
���A�7�<D�\�u)����e�w�^-�YKĔ�j�/��T��?�.(z�RiPT�}�i��K��jA���v���,�:�8��1�u�� ��g�	�S7��.�z����Krosh .V��p���^u������g�fL����H&;u`�Q�<�eh]dc��i�=��w������7":�@2_�`�a���#J�jt.>��������ncC$��s����R� �	���w�b�<9��� Y�.�"]cm�� S���{!�Uz���tB��f�Ȳ���͐�aK��vI���;�hLC�nZ���ܧ8���!�h
��(A���W�_��N,+��#�|[;n���$���<k�,��}(��}:E8�,��ir��ǡLt��ш.�=���U�4����-C6��ׅ��nR���2�%�g��$;z�m�gl�R���ѝz�a�Z�H%J{�Ѝ�,�+Oz�#r��^�dN��>�[��m�`N�%tz�R����P��w�k��ǋ �4�M7�x��gO+��&�P�m�qBZ�I��؃2�
���fA�87$���=�OG��噗b�X<��%n�mG �m�j�u���n�
�	4��'f���#~z�ˊ�v��Uv]X�^��e�VIg�*����_�3'd���b}m�"InП*�����9:/f�����~mXwn���U.�wq��0%�ɚ���-�wO�e���x�oݩ���G�Γ�L��&%Z�����~�����1s��H׭����L*����2��~(�d<��mjP���g���f���nv*v��uI����p!SlF��u�j��+ɰ;�;?���-�~����x��G�
�新d@�D7Bv���~��H}v�ւ�+�ً�s�=M�y���b'(�����w��ֳ�'�a2^��72����8�x�e���a�*��L~�A�\�C*&@'ŧYQ��`����8�RF�$џ
oJV��)O��a�^���0910��0<e؀3
�?���cI�H�ٯ0�� H􌎫�j�#��}���R�!���^`>��{
�w���2��&O��+� �����ݠd������9��N걘ڳK�0GBP��%�����2�B>f����@����=���%�J��� ���K��ǘ|���9DbS~Zu�t�a�Ĉ�
�{���c�C,��)"YT]2X�l��T[d���E�R�����J��!����ŀQS!����d+����6u}���l'�U"̫/*`���D��Ȳ˳�����p��uQ�&UL�_}�7�QYT(RMB@��
 �Y�9;����P���^�{3\���k#M�Y���ג^9z$�
�d�ub�)��e}�]=�8�s�.V�$����^l,02%!*��oE����i��Tw��P�S��J����E.��](�#/!���ȵ�dЀZ2T;.H�'�T=�����Dh�]����ŜA����xn��6qنi��/�Ȱ�FmR�W��
�JR�Z��1z�b�t@8�DX���/�je+~�w怾*��(�X�b��0���w���N����?}�PK    �{?�~z�  �     lib/Statistics/Basic.pm�WYS�F~���%��m�}�����Zb(�R��D5��^���(�==3�,��x�,MO_��t�vl˥Ё�4$������2|��h��x&K
�n�'���FPBfa_���Z�2��s���i9s�z��9�^�@y�M�n&0�V��ӧv�՗'D�K_7
��Ln.����@�<>�z�ϫۻ���7��;|~��]�NAC�����V
15B���9~RS�J\ 1e��I�L��E\��T
�4��ABӤ�x5�|_Sc����\�.�bæ�y��+�����Bl}#�iSݱ� �I��ѠBmh�̖_S'�O/��I �
@�d�r���w�pB��[�t+�r�t��\�����<���%��*��ff��$h�t.������D4)�"&��G�T�"əx5}��z������o+�5/�SQ/�p+�X�k0񢽝
M�ys�:`{��>![#v���ʨ��*0F�]�==�rz9ֱ:Q�M���mS[��a5�D��$랼M`.����;�?��FEexxK�T�3�,5�vj�e���K=�.z>���s����v����s�`�����?�=cj�=e�u�\���jb�W�fd�����
�C�L���OI6��'�\�'bh��(;�8�h9��Z@:�7���0dGx Ǣ|ﮟ����@Q�n�I4�]Gt_�,҂�w'�SBc��a�IbiJ��T���I��ci�F��PK    �{?pd�    &   lib/Statistics/Basic/ComputedVector.pm�V�n�8}�Wck/�^�o6d4M�.���h����@Kc��,�$������-�x��i8�9s8���'o���Ls�y�^�c���.�.�4F_0�B�Lw�`����m���x�f]��`�)�%��<?0��d����)9�L�P�M�d�J������o���E������|�<�*[���o��a3����k�U���i 3޳��l���c(@H�`w0|k�7�'���eJÊ���4���eʃ,��@E��RD��`�%�qʁ������x��ȋ	��{��0�& 2ݶ>��6q<ٴ�g0L�Đ�a� F9�u&�2�~Q���H�u������C|:�����2,�����]�6<�i=��Қ_�mn�B�OY�ِ#�k���_��=��_��� �z�BY���:X� �\�M�0J\��J_ƨ�"��RY���� �Qbb�'��L�1�w�.>�_z�rJ�Jז��.��L�fךǳ��(r49�{KCJ)����3�C恿p���`�)q��+*R0�u��F��K��f�~?@�1G��xGҕH�zd�E�S�H�缒b�ٹt�HI�����bt���������	Z ���N=�H�����+q���ॕ��2�x��]��������W�X�%�ܕ�B�*<�gm>r[Z�t+Jno�=yVA�S��0����:���*��L���#���!۱=���2�� ��I�4�|��G�k!��_���Up~}���υ���d�y���[d�ɛ���׷�f�!źS+�[����sF_Xv+�m����C�k���D!�䝘���VN�T�{N
���V�e��� ��3����N[��;v��måKg<sΜ����B"�н6�m�g�L~6͕�9s9X.��Β�'���x��u8|G�N��Q���[?3%�|��ߔ��w�g�:i�K>翑�\�O��$>�j����^w����G�a�Q̈�[/J�b s����
Q������}\�v5,�Vm�����%�l=� W�UΞ��"@KFK���Z����UuZ[��%�K��'������Y��Ų0�"�M�`<q�y�
M��3z����Jgq���k�]aYK ��b4`�!`ɻ`</���TP�$G_`J�V�v�	8-]W�E�i���n���3E���a�iyhllc�U7���QU��*�l�7�d�}T�������Ft�J��j��R���f�]Џ��O��e�ε�n^3��}���Z��8��S�Q����d+8�88�i�YTs���΀��랯�}���_�.v9��t��Ɍ��JQ7-��� `�����/lkF��������2�W�/��6M��W�s��ao3ۊ3�H�7�ی��B�C��z�O��K7�I���͈�X߸���~{����Y7�V��t�>�����m�I�ۉvUy��Z��չ�nH�I�PK    �{?��9  b
  "   lib/Statistics/Basic/Covariance.pm�UKs�0��Wl�L�XG3m�N�����%�x��?RKv����dad�i���V��~ڗ��H90���R	&�.���cV�\Д���d�y����{���h�f{չ���T�`jn�4OEz#��G��[�%�e��|�~s��|��CH�l�[O�z���
N�
=� ��lms҇�
�z`Y������2�5"�W���j@RHK4A3I1Ooԭ&@ބ�b2�"սe��:n?�|%R�{��u5���_�/�~�aW<�7	������ol::Z�y��֜h(;�2���3�q�W�J���k�VQ4�*'^I�v|��(W�Tm��_�=8{���[�
����FC3:�
g��ˑ���y��)q�����?T^�z1I��k�����G��a8��,Gk,Ls�g7w	u����<k�����g-['��ˁ�\��~��_]{uS��H_��&�n���Dz��q�>��N�����1�0]�Vv����Q�PK    �{?�wn��  �  &   lib/Statistics/Basic/LeastSquareFit.pm�Vێ�6}�W�,%��ڏ6�
(��~��q:˳ח�l*��f$�J�$�d���ڛ$L����B�]�6�)�*�uH9�c1.%zU:�p�,�g*\l��^�R�<R��["c��2*RKC,��M�G7S��a�$�XٮN�2v(�gHX@b��9"�S�t�hj_@�����x5;�쭨^��G��d�5P�|e���s[(��;��o��J����4*�ՊB>]F=zu�����k:O�}RA뢔6nL�O�b1�����QE��H2I�媉We�ƪ/|��#�W�k
e	�M{"�Z��s�`Q�+QN`�l�ؼ1G>��%�.���IW��1���T�N��e����x���w*5���<2�|�d0��ٔ&~�+����>w���?����@�������:m�SU���z�Hh�[�X:}���4K�~�M���y��J�=�a��_.A���j�dkW��J����[�Fz�t�	ѥbe���0t7���f}wN��ܴ�
W��R�S�W�F~�9��>��l8q�^��h��s���=��-���Tum��ު��.���0������{}u��tM3�$�O`y�RӮ��g����D�x�/Ȁ�;�jZ5�&�PK    �{?�4,`�  =     lib/Statistics/Basic/Mean.pm�S���0��#)A��t{���z�z��K�B���Cm�U6��;C`� �߼y��^H��!�a��
n������L��e5�/�p��v��u�8�`������i%����OL��g�Z]!ʾ+���V��"�i�����S�`�%30Ϣ�B.�U��w�����D�+E>y���>���>C�	�%����L�9:a�#�p�fD�}����CA��u�^`�pa���d�ܤ�mƫ�n,�uX��a�F�Pg�@��XДrZy�N�&=�հ5�)1tĐ���ȣ�2]0���L#g�O�w9��C�4%?L|�Ԍ�&]3�Ť�'�w��mP�2#���Q��1�W�)�s����,l�4�
!%�1,�R��������e�Whޔ�2���5Ϡ��ê������a�"�E��5�x���YvCdP��%����p}�����mgmE��G��Y�GD�����r's�U�wkf6��r� PK    �{?����&  �     lib/Statistics/Basic/Median.pm�SM��0��W��Z��m[�T�P��"����ImgWl���Ǆ�BZ�y��y<�B!�!�m��
nf��>���`�<�AP2���r�P�eK��2�j�m���L+��[}e������U�K�_�д���j
�����c.�1�� ������ ܴ��|�O� �0������?? ]��G���A��`'����gJzȓF|b�[Vtڧ)	��Y
���])wmW	S�|ӫ�)1O`��'`e)g�  pԖ��yu4�)���u[qd
m�3��ڹk ���x�*�����P�lqv�U��&��z�|B
G�9״������"�uosW��r�>s;@I/��h
�����1'��>|dV��?u��uGQ��+{A8�,�m�r�VQ�X��n�~�QB��n�+3u�D�ędf��섄�}��h-i��a�3��=�K��N��iȡwh�fE�L�x
�l��c;�K�]$P`�k��_�ϳ�As����1
b���հ1��QҠ�����%aA(��֒9��ʢܡvO�h(+7�Jm*�r�T4ɘ���M��ϧ���u���o���ﬆ�^!6h�@X��-*]0	L��R����Z ��������]0*����g��U"����а�2��`�Y���fɉ��dϬ�:��*wE^��}��uqɬ%mv+J�];��Wح?S-�kU����ϿC��a�Gm������. ����)wT�㵾�\9ˈH�p���=y<#�p�s��/�r���!'%1���j��Z�{ix��g�qw:C�K�����MCt��O��SW�� �'U��3~(�O>0�d��I�-�`�܊�(�Z���%�b�E@�OHN�o0�ڍj��"a�1�RH����V� �������8��[�T�1ũ�{e?U�����w�7������E�!]:�M��{�
�w0��.�����a/|X$��Tcg��d����d�Rꩤc��Z�R���F� PK    �{? ��8  �      lib/Statistics/Basic/Variance.pm�T�n�@��#l�&-q��(u[U=�=D�%��z�U ���#���;,k)u8���7o��2�D�p
��d,d�W�0G�>�Hf��b�,��	�Z��UBݮ��ZK�A�<�dO}^�<�Ӊ��^�|�?=D,ay��A�	|Z�Ä�G��l�SH�l&�$��0]·<Pw�̡-��A.͎;��l��$c��ϋ˗/�? ���<c3�|�� 3�+�0B�GoX+�,�EG+�Z����
h~��ǜt s���jM�.���҃��,���d�OZ/�{������2�Q�m�
��U`Q��|��%
S�G|� V��λ
P3>:���gp1�}$�|�3
5A�aYQ�6RQ	�i��t<�g�{ *�J� ��X1�	�|ǂj�1n�H��_C�fŭ9%FI�y�G�c��9�2N�(*(8�K' %۫�G���^9��L)����y��߼}�le,�nX�5)7�f�U"�Ίå��S�5�s!*�˂v���s��P�h �ތ�[n���dO��c�e���P[
��)'�׍�S{;�P�n
�� �*�R��m�v�е�t�YiGܩ��ٲ<z���8�\
�Sw�z(��G��'�PK    �{?/���  *  &   lib/Statistics/Basic/_OneVectorBase.pm�T�O�0~�_q2՚0~��]:�Vm��1A�P�$�6"u���*��l')I(&���w�}���$f ��X�8�'T���w���re��rA�%
�/U��W�3���OStc�J����^N���5��~Ҙ�����o���f�@��^���/v�Kכ���eRuK?%��@\�#�X�`�V��5\���(��������j:9�z_.�?Nϴ�q�m���-#��U����Q�����htV�
շT=�� PK    �{?��E3�  �  &   lib/Statistics/Basic/_TwoVectorBase.pm�VMo�F��Wh�&cK�z�J�M+4����\�X�#�5��w�T�����IY�6A�����}���͐gq�`�)�"�"_^�f2��&���J���JLc��"4��a�<v�G��I�D�Q�a�G<���W&V����A��x&X�Z"���1�%0ډS`P��kzm ��M��1���\P��
IR���
V%r�7�3(���v�T��H�h�)�2Z��
sa�=�>�}
����鑑SJy�׉y2���U�S)��F��f��
�
o[�FS0�rMul�]��r�����qj��.�����2��I2Ai��dp��UXz��$�WE.|���S�c���v������~�����DM�Dե�1<CHm�Xy���C*E�m�q
?p���a��N;�׃�a��D��6���H<g�O{D�ѕ���^�_��7e=|
�+�J�
B��d���(���"������C	�Ȏt7��܂W?B��1�
��Y<��b�x
d~k_;b����^�h�>���Z���9��$_�*��Σ-�y߂����7����W���;>E���L�kV��3����t��=@2�Y��ŋ�c6�{���z-��V�����EK<������}��V��<�X�+������m�����7o~�� �>��,�}fW����eC��`��/Km��b{�F N+���G��;��lf��q���j��AH��`�$	Kl3O@���W	���Nݔ+A���\&0?�fH�>vHU3k�'�*��qi�����*�
��m5��߃+�&>�>{���aQX��O�\�Yb��͓�V����
����)�p��`����jh�0&J^�<H��B�	T�M�
=�W���-�I
X��՝���-�6�I⪍v7��x���QH6@����,���Wl�<hL@��,z��2���� ������O���5�xN~:��.�	2;�z��O�6|�$��ƃ% ���^��!M�[�fR��Ĳ�� Tuq�<��:	�6�6�T�8��"FX�gga�������â�> ��~�����I7"�4Eo��#p4I,��m`i!�'y~��"WdE�Ą4�3���b��g�%��K��h� i>L���_VAy��h��qP�
m����y+G�Pm�?�c��4Iw*/��9���脴~"KLy���
8ސ�g콆��w�ĺ�>2�1[�7�]*��4?$�q�BJ��#O�t��
è�\��u:LI�!0S��
��ujn��4w#�5�1�1w|쇘����E� �W�Mb\��4\�H���u��A!Z�Jh͏�:H�O�au^�!(��
vڷ�� �*S�Q
&�ǉ�#}H u� �nH�Y��Hc/,��¬�P�4�Jg���D��BF�ơ���`�?G��+"�O�<�7�"�X�1�خ���h�����y�Z���^؅?Y:m:��9^�kG�h���>�.u� �]��WTH�ɜa}��}K��Y�@#���Sqh�-�~���������1��/		�1�0������(�8g��L��ji
�d��V2 ed�4o����@�����G��ɍ�r��2O��f��;����5�9/��th_ɓL\;�\��<��[f� R#��uŹN�B.ʔ#z4r[�H1t�-�_��Z�����:�l�	���9=B��`��� ��Dv}��/$9a�4�~�ZT^�!Y��F5���#�ߠ�j�
E��z��!;���{�%�����Z��Q��5eRO���g��Q�T&�eB��@�V�{
<�������gyjO��W�ͣ���3|XT�E�Q�0�
��4��/�u���I?�Ef��G�t�Y\�H�8@^�P��ϻ$OAؑ�ލ��AP�`��.�=���W-к"�����K3�R���(Q��OV�l}��w��:x�
���7}w���_�|�B�����y��J��}���B.���*EU�y"�I���ɲ��&?��m"��7ŶJ� <�6Cq���rW/�e�	_��*ɈTB "��}��	���YR��1�d���@�+��X"/*��ւi���U"?'�Gq_K6.�| �ō��gY%�r T�b�e�m֏Z&�F<������t!V�|A��x,KO��k��i��v�^��c�>6�b.�^+z��	&2~��/��/� ����d�F\
%�'>$�d�B�˝��<~_�&�E�Wo��\
�Ï���(/s������/Eg��7wW�V��%�z&|��o"����}z
�����+~m�Z�47���:]�������/0����6I0�V�,�v�wE~c���NP� �
�v�7G|��k}�Y|梋�"���k�Q H���f�R�
k6��P�(]�)��}����)�0�U�rw0���ѧ���K�b�8"��mZxQ=�o���T_~P��h�L��3�쓆z��]
O{�!��f�����\�֠�4�w8TG�N4�%#:���p�iaO�_�G�h��T��h&��#ǵ��%�4��c��8�/mʂ`<���$��b{eDJO�+z�鹠��,Q'뙧���> �6�n��._b�/8PQ4�8�bWz;������N��{��E[S�A�.JBo�����N+X0C@'x|��&4�
󉸧����
u�4'"�|p=�1���rr~Ph]��Ǎ~g���R�S��Hs|�$�۰��h|m�8��N�T׊��ͺ�nS`�uj*�׺�v�|��PIO_p�u��:��3�X�
�&놔����� ��ԔS��� �N�x��{��*!
��x늣���G��V��p!rEp�˷>�s��`M����#�ziU�0�E�!]Uu��r�[�Sǃ/�F���H%{|UR��SE�-Ȗ��uN|�&�TbZ�԰d����0O�?ʜ0��&�G���07�9qգ�q:9�U�/�O_�cz��@'�rf7�|g#1���@\p�4˴B��Y����;�����x����-vե�ar��	��n��e��߾Tb�Y�n�o�l�nC2�ݽ}���P�s�.DZtY���J,��.ÿ��[�,��%+��u2�,vb�T�>Y����9�d�6��PK    �{?�Я��       lib/Statistics/Lite.pm�W�k�8���+�ws�k���%\��z��8�����%�k�]G����$˒�4t�q�$��}�G==٧�$0����,�X�'�8�6',��W�E���~M�1+� Y�I\��;�K����\~�~w�f�����߿�>~2���_�~����uo�rq[&����l�"3֤����c�r��޸a��B`G4�r�$)l�=�<E���@�-�6��A,��.q|�i5���k�Y
��6�:�"7<C�(�*gt�x1�
H��vud�/��H@Vݥ�� �6/�
{����	��o����㋋�O#���X�`\<��!� �w��Zp�&-u�=��k�	%T�(���LVԸ�t�fT�*^ h�˗-�r�/�'�9�+����4F�H�@DnHt E^�QtG�c��fpt=-�_�xT��
����[�bv{J��};�tV]�il�]���WAz�_�׷k��6\[�Z��w7VܾY�owSVk�D�l�:�K����}�B%�f%�+����N���$P�]�ݦ�lk9�+�X�bU>��x��tF�+��}s�᱆<��C���Lh�a�~�k>�q��f"��~�L)��L鈅V�9��g���TX�n�~���'1z��;�$�S��~kJ�,l���8%�z��s�S�� ҍ�Ə<P����$٥��j���0�j|z�a�קN�k�x������o�PK    �{?}�NC	  "     lib/Statistics/TTest.pm�ko�F��+&���d��� [�[#I� �:�}�+`@G�K�g�T�ˤ>���}��KRrܦ�N@,��gvf�y5+i1K�e��n�l�&E:�I����K���dIgWW����j4\���𖀞<>��aI	PV$K��mX�寏��-~
��8��zq���g�=����?��޹�d�.��nJ����E��b�"��������'{��U�̇��`�x��p� �ㄤ
S*)����M��
㳋��_��ӓ9�S�p�
�E���C&dA��K�aM ����B\fK���3����V%epC ,���;N�Pz0B��ji��l/>��
La�r�YD��.�33Ӝ���|�%��,!"���j��Y��=��Ll�[C����9�n�P��%����ˌMF�U8�W �� �̣An��u[���>��� ���O�1������䭠
�΂��sS�����RE�V�`�	�	�Z�d��PITG�T��@�1��'84@f ���{4�W�䰝GN/�e�hKU�x���~왯�M5����jh
\M���o�"Y�Q��՞��L�KR9�3�LSi,Ӽnˬ��`NG�^*�]*:o&%�$����o��������$(�ld������+�f_7�: �w�^#6��n��l�໙��X}���L���l(���7T҅c�f�m�3;���[�6�
��U=�+7�]�E�mv��ƚ��׵���'A��CS��-txs��ڈuȱl�-�f�җNU�5�M�3���W�I�:+Yw�����^L/�o]F^�>�V�5��Os�g3L�)��'��8���X��;�z{}�Ӎ��M!�ğث�����q�
��/Y2�y����K��,:�s��p��۞(�mm�Pѱ�����x[�r�
��� ǌ�ʄr�F>?o��x3���:5K( ����4��Wp��t}��_� O���K��گ?�<R��D�ρ갗���@=�Sœ3�Z�P������z$Cb�K<��������&b�
�l<B���?�΄���V9b�gq�\Z cR�0g���f�����o%j�J���j�n�yỵ@�FD�� �:xX�����4m�Z0�����p\<�O@�(6a�YDń���݁�/���$՘��C?D1N3��<��1D<�k
7"�J�Mt��~j��܅�I}/C�k�[��n�,�0RN��FvX��+�i����Jt!W��j<m'P�,-K#�[YG�@�U]#�_�?lV�gSm��`R�5M:�ī�^Mg�X�5m�\s�>�6�_s}u]�k�i��\5���a_ߨ�p�=ߺ!�4PlJ�wy�F�J�p�BIqE�pt89�~rt����)3~=-��A}z(��:A&־ƾ/�p��F��^����'��d5F���E/��^1�-^���J��f��|@q��&e���"%�0�yqĬ�ox�52����'&�7������l.t�ٹdE����a���$Ѵ~Q\�/���2w
��F��_^]��"E�Q'�b-�z/ı+��Ի��a6f��#���6E��"��=VtT����*�"�.���}������QQ��ˣ�9�d�@�������o~H=>�l�=�v^R�py��9����F0rՓ-������T1ԓj�hK��
ɦG�Ǯ:Ͽ�؎������{�C��F��۵�e�7]�<��TU�kB
嬑�1aWRu��|1'+%�"U&�>L0ʥ�G*���H�����Ӝޢ�Ws@��	�t�4KЁ/�kWK#�e��\�Yj��)mR�xps�AY�a�
��iX?��T��OǕ��0
9�ysm���{��p��8}����,4�#�r�as#����XIEE.h.�������k��i�*o+�Kn���ڂ�êZ���r2=u氁����@�� �X�}�m0�:X!�k#O�pB�!��������:��`ML3M���Ӵ�X��������\��0���i.��7�6�kj
kR"1��E���>�k _
<��l5�jYs�<���;�9�%JI�lW��xXE�h���*�i�yjI|r��4>~�/����V��l!�|�ַ�]��5�v�ڻ�ش�W}-��YY�H#���YQ���p��<d#�w"�n�.���Hu���fQVpZ+:ۻ����V�UyKX�����g��ʾj�)��Ly�M�i]���Ę��o�f�n� v�����[���I,����_Y�����滈�	��;��[w@�^t�n�Mo�Թ��u��u��y��,�^>]X���T�#)A�o���2Q��;�ҹzc�y:z-��L:�~Oخc�j�������w�(�O���0�׏��?S!
�1�ˈ�Dq\']��5S�W;���z)7p�d;Ja����*��������CA[�qo�m'՛�����~�����MS���[I�=�]��8��Zɧ_���ϖ�8�S�lW4Į+����/�(
�P
�P
�P
�P
�P
�P�_H��V��Ֆ��J|^�&�\L�y�w�����յҷ��z�%��$&�����Y�a��
ԮI(����
͖���l�9���nvK�W���K%�)�!,�i���/���Q��>���]��-�ir�ȣ26��tXx�.Z�

�X�4sK�&^X��ɫ�-}�y�Vb�=��=�f��R/���&s�^�F���U��AZ��@3f*��<VnS�͆-d4�᪕��8)-z��:}�9���8j�3�~b���-)oC92n�-�OC�=N��A�_K�`���n�y�w^\�:�w^\u���
�Y�w
t��"��@���h�V�AqAzxn,S>��oC=2Vq}x�X)�/zb̖����I^����C�z�֠��b
��T�Y��%���[}�$�6�Q�p�2�1�:L58���0C��M��Y���'��W�y���E���A��
>��U�?�%O������W�Zz[�;ZzYQ�4jHǦB�ڱa�"՚5�_�˫��������q�Iҽ� �O޽���LW*���t�{���yC�����!=����`=�Z�Z�%����SZ��O�c����f��[R�Z���"s������g��:��/G2��Ҍ�!���=<Ri��o�6������Ne٫sZ=�/�Q_��I�P��B/����������hb�$=�-��9�1>ʘ����P5jS�KÛO�<z;���#�m��'����W�hv�b��=�P��E���=M��7�mi�4�mMdQ�O��T��?�X
�{��Ԁn�Z1�!H�C������2ULU��~3u�Ë��;��t�.u���#��Kڽ[�ܐ�{^�U�k�5U���ye���6�f�B�&�|��T�3�^fŋ�I���w��<�~T8|j3��\��`eX>�����,ǧa�{�Ш�
���uh�y�6���wF�)������6��3��|N���t�-�*��-L�eA��O���	S��a��m�9j����'�"�G?�J�0(���A�&UvL��5��|~���)
��G/4�ρ&W;cO�N\�Yڅ��bq�H�XQ,�e���b[g��O4�+Uz�06ߣ��Y �1���1x+�~A�\��;^��3z��a��' ��G�Up1�~$���}�_�o��~PԛA���z9����Q_�z5�y &蕨O�����΢W�	|��?�_'0�YJQ��7D�=�)����pB@��j��{��'�Q�x,ap�7��J@��<���p�&�:OQ]�z�*��>
�%�t��@�5{"h$��$�ot����00�CHM��O2h��үS��q��S��^0���?�gu��~@0��1K	�Zj�U��s��"H7���M�Y`G�F#�e:e4�/�ɣ�P7x4N��d��h| 0F�?G�E�~d
x���D���8��
����9�&�.�D^y��#��?↮�]P>�SG�V����ܼx=��q�CT�8e�V��?D�1K�8�O������a~/�^'56�,�`���R[cF�XF��SF�K�Iq�h}8>N-�t��::V��b1Py�@=�D�:P��O>��y_[-��˱DRō0{Jj�:�c�qZ�5V�� �b� ����)�� ��q��Ձ^(�����1��$F
�[ZDkU�� �'Z9Z�~���k)ZA���xR�?�V��S�#�h6�j��<b�V�G)��ڀy�9M�̣����<� ���Q��A�i��� �GΣ��>��#�p��f�Cу��#јG+ ���G�6E�GFe���5�oł*�V��?�p�V��)EΣ���G+�� �Q���1p�R�G�݈��ߎ
�G׃��
�G� �(e��%Gk	�mQ��ٳ��F!\� �E��+ܲ���b'�EJ��D2��(�p5"J�J/GG
�r�u������-г��g8��N�(��L���ſf��#[���0�u�9�Rg�:ܿ�w�{7U�z9���G��|&6C��-R�+���/g�;b>�M�������I�y:����ˡ����'U��f8��FG��$1
*~��.�wc�/a�	|�Q9�ʉ͐yI�=�B>��^i ����0m��U ���P���_���@=&��i���X��>l���S��}Z���D���a�i?��
�}�g�	�m?��cR�p�D�X���?�����gmT���K���yԙ��f����#�V��N_���7C�N����r�$1a�����bLp@xY&O!��\
!�U����p7�BخK/!��	I6)Be	F&|�1a�"�>�-N@X�{���>�M�(����Q.	���B�"��$��	�C'A܂�q�&���y.�@}D�ݗ#�zYF+�� s^\
t?{m:+�h尦i�O��9��8p'���]_�e��^�� ߆�F䛑oBތ|�+��#7 �D>��9�g 7"��<y�_#_���U�W /E�y9�J�5��{(
2���ty��"Nߚ�gw!^KZ[�F��O"�{Y�&�/�'���~:##r��+��}UF�����T����^���K��<��2�♅��>�Y�pAGK&���3ݧ�|�I��,�p�U՚���ڭ�Rk�|�Тo?�i����Ƿ�k<��Ay��g�*�)�Y}��<��\���&�/a��F�_Co7^Z���%EV��~�9�܄{�3���Q(<�·��g��[��~��+5Η�g-n��j��m�2C�KO�_2G�ԅP
�P�WO/͗��}]wеM�ޱp�I�z��9.���t-�����躑���:D6G��1]g��KG~��NW!]6���j��I��E�-tm�����>]��z��α�Q�]~���[���<ކ�ù���b�unp�
��+X��i�ӹ�����'��b��~��l����ܛ��(r�k���J��scU<�j���ƹ�����9	�(��:	�u�Ѭ��hG�jS���
��v�����BK���9��B������,��6z�4��Vۼ�W� ��T5:�Ը��t��勪ָ��yT���Ҳ|�eQ�TŐ�<_�\��/m�9ˮ��s�2�u�,�ZB?�^��5���������9&���J�J�J�J�J�J�J�J�J�J�J��?��D�of����T?�ԥ�\��v|q�7�g��{f&�N�휽}�̎6���c��ɸѸ�x�q��q��Ɨ��?5��>�&/9/-/;/7o~ޢ��y�����<�)ɔf2�ƛ��������
LME&��Դ�Ti�3yLי6�~i�b��t���.�n��Ӧ�Lϛ���1}h:i���g�07�0��3�S�y�y��rs�y���?�)s��ə��P
�P
�P
�P
�P
�P
�P
���i��i9�ξȾ�7�TZ�ଫ�i�:3{����N7��5ު��R��{S��7�}=x��
pe����9��I@�d
-5D�$�/#�h������c�tL^PNy�)��/7$�/w��uq�i���z#ѱf|f���ťs���U�=\�M����4���UYP�;��?�(%��q�r^��Q\Xh�e�뷶a�dc��F䟮M�f��QTҸ�ՕfW�(+�/I�6xK��.��/�H����PK    �p?�'�A  t	  2   lib/auto/Algorithm/Combinatorics/Combinatorics.lib�V�o�@~����"�BeI�qZ	AB�DT'��t�����(53� ##c�Ν;2gb�.>�N�^���ww~��ݻｻ󳗭Q��J��ђ3���U(淢z�oM���T Hȗ �1vu��ؗ!B����F�T��4��ͽ�qm�c�sGN����<>GpST��a}�T��2�sh���)�O��dָ��;�C���_�$x)���#��4�0�H	dH��G�;0��e.�pAL�3T����#5b9���!kDG��M+�fK
|�[���0�i�0�pc�P0�� 
j�6h�k�t�۟N���J_�bJ���8ݖ�Z7��	�7����
�g>��U��njO?Cʐ��.�XKg
�r>�WkNg䞺<}��B���݅kx�L���iX'Yo>GJw0DG'z&>+��̄���|�Axe
_�I1��4�<�*��uD���;3��s3�2�?�AZ�1ݙ��2&�u4c��ጥf�m"���}
c�V�r��8�YX�5���Q������g�O���¿�sl	�!ӐS.H�ՒMj����Y#|��g�S��L7���?ӧK�Sz�6i�5��	��o󄢔�����}��PT拄&+	M�Kh���WB=��^$4]Ih�]B5�U�z�G*O�xB���%�����	}�oDBK����%�Z��+��P�	�PZa�Pwhu���|��%Z�$��.���"-��kB��r�-��f%��v	����Jh9T���+	m�K(
ZQ��P T:���)	��K��j�WB-H%�O(YI(�.��Т�&t *ߊ�R��R�J�V�%

�x�u�4�K��9HZ��+1��������$�ĕ���왽�I��ӂ�
�\��ꇂV����(yM���r�~R e�怂��X�L��L��O3
)դX�)�+�&�E�T����)}�d0DD��,4b������P����gi��r��D��"B�m�������V
sO�V����y��Mm^���f�� i:�76#��̵7�{K#�.I��5wwg�v�-i6��{�T�f,v���l���4�J����4)4y�J��s)��,���B����a�5
�0�':�J��6�4����/$+�r2�`�5����z�S<UϜ�O�+�DO�A���h0��TO����ϕe���O�̵�����ӡa���<
c���y���-lJ9?�9_�b*g���"�S�i^��rnӟf����{{�{z�DK�?�N��m���Ӌ]�8�;q�W�o��V)Æ���]��ۈ��h���̓$o<k�6� .�!�s��ᙿ?iBA%����C���������ߝ<�}߬�������V#��&�O�����{ɨ	,�9��gf2#�(��#]�4�8DL��'��&r�����U� �m��Uj�ۖ����T�[M����7*F/���W�6�W_����6F��T܄ 5�Rq
ؕ�EV�TPq�Ȫ���k+U_�LE�3T��h��`h�k���= 5�U��;4Vh���X��nl��������׈ cc��o'�v��Y��HS�U�9�H?7O{ �4���7��t�o�Ӗ"]f"Nl��e�k�e|�2���\��H>�ʳ�gBh�H��*��6r��R]��}�P�̯_7T}��)}Q��Ho��L|�gƓа�H[Ɠ��<i;��4%�C�������>m���cIk�В}Ҕ�����s>�BcDCa��p#��@�(���n�P�,UP�!z�Hc~�@ٿ^7���r~<�߀>k`�^u�+�o7PLr���r�Kf@:�� �J��/�fOi��&%@X�@��	�|��.�
 h��S�ጦB?
܏��<�0�5eL�EОz��>���&`���H�9w�c����)���K�qXM������B�����ί@*	�V=#я��tr�T���u��~�Kqr�� X�j��=�u�7tU����PW�6�P��ܱ��`h�������u��j n\W������P�y�u���>�Wu�� �H����t�N���nD:S4}	a-Mf`��)��U�� DZG)ʌ�T��g7�h �Iu��T�P���֔�\��co�6���*=�m^m�����joЈ=Q��'�T�"<f��
���u��\m������W��6�+�E� N"蒯�2{ ��U\f�4�/��F�"]f"��O ����l�o�F����Mղ��Su��q�#��H�_��o�Ւ}���k9��Q��Uڇ�c���l�x���3bcp>gcy�"G� �"�Z�$��� �_��#���Q���⟚��)�p�G���TF� �P���a���i?��
toM;��+-���b�Y >��/#�\u�ƵI�!��)[��5���2�x�Z,���5�m� ֨�A�E1�x�������k5(Nv
��`e�?d��q�R|���Rs5�E��	%���<!��L�+4�;��^U#xKu8��\?��%�4�ٚ���Wos���&�!t4"x�m9.LE: �u5<��WC�K�Ȃľ�X��KY]����x�b׹JӁЕ��ڮ�M�1�Jr���O����GУj���;��7������̀������<�(V%��x�{p.��Պx�5MT�
��A)U�f�i��C��U��K��,��:������+������I���V�;@sUԓ�ޭ*�If�
&�~�H��+�6���@���Uԑ��ފ
Y� ,�(��I���y��r��,��,�р'+�H5p��j{� ���	��sMa�j�Y�(�jE��T@V���1ů��d���
� ޯ��L�;L�c�)�C�b�M���la�b�l(�Uйlk��tV��q�
� T�
�	��A(�)��/��<����UJǭ�C�7b��f��O����7�
D���CX�5�G�fy���B����n��h����� �����/������逭�
�h�})�>��r4�3B�*�4����)$��R�)֑)�ʄ)n�V�<�-~D��F�b'�cF�-���Xd�[��r5�7�(h�B����w�d�E �"�j��~ר4O�T5r[�I� ��z$�Rr�қ��Va�WKz�yI�^l��tHZIոh��PR1.r�-�%u�]xcIŶsĔt���.����h~AQ��"�DV���{�����Ȍظ&B�*U�m-R�s�Sr��S��؏���d��w`�g%����!�l|������;Q�X��(�,��O<�����UB�j=�SB����+C3�Ė@e��i	�2x@�.gQS�r��J�q��MT�;�t�,�Okn��nv�A����N����v�i�J �ҭ�
�
1@�Cy����n��td5��M!�*��n�u�
7E846;�} �9ɦ�����)j#��Re��q�(	���j
2E�/0�_�)nH�����jК��S��b	�W�0�D�0�L
x�A1E ��)Z ~Ǡ3E�u
���*�!�lo����d��g���_���U6�@2E�|�YQL��NXb�-1�@ꎈ�)6��Лu���ȍ�&���b�� ��ɪ�o(ދ7N2�寫���X�rF+�����P?/ԩ�M�_H��X;_h�I�+Q������=��7Āg�_N��	�@�Y,E1\93b�@7D�xZC��Fˀ/�fo�W�(^�?
���P��a���Ge�^��������^��D��Ga`:����-������+]1�0�B��������G�y��@YM�.;0�#�O�d^՜��2��"c`1�?-P�
`y���lI�F�+�1� �Ax�@ˀ�F�+_S���
e4%8A��PO}�2p���
���,#�]���W: b���@3]��2�
N��90��?�P�vA�O�2��j�,�/~�0
�ϩ%Z���6���Se��F?|����Ā	���T
/�hz7�@��g*�5��?�0���1�1��)0���@8�$U;>x��4DĮ��@5͞i(�³���+y�v���_�����g�K���S8�ѷi��c|�Yy
CL�S�"�ς��yNv�
���CX��� O˂�{�#.ˮ��4�B�iO)ލ�
OO��6�B�Z;���1�z�q�JD
7VK�X�OQ��2���oˉ+4�K���V�����] �<%���dO��w�O���ߞP���;��O�ܝ���X�i��/C�uO����펱��\B��OT��j���;���m���i�{��s��,�������# o�P��c�ͧ�ݍ?��������a�Z� [����]�
wO�ܹ����A�9*wƓ*���;�	�8֞;�;�Ŝ�� ,�Q�[K�>���O��F��r��B���/0����;�c�����*wǊ�����������ˤ�n*�<V�ۨ�h��q�Q�=V�k	���*w�,��{��>���78TrB����_��@z��V�1(��)����P��{�<Ʒ�W���<�k��5���As f
,V�� ^��$�@O0"�I�[GB/��X���� ��U\l\7�A$H/WT�!R��2����d��;�&HAIyAұ2�Ν%�&Q�f�H%J��#I�|Cr�׹�̝�g���� ��x��^%�Pg��W�{�$�U���WI���>	aF/V���$y�*�a}$���y��8�m,Ut�+ٿXQ�;}ε�Z�}�� [��Mʄ����A�X!�s���w�B@Win�0Z�����b}XNŨ<rːcX�O����Uz(bO�U�?�Q�k�tg`����a���Z�fG�*�djC��Q�{��*�갦�N�a�B�#�J_���N���K3�&#��GJ�`�#�J��xRգ�ҁ���9����<w� 4|���	X�G�+w~�x���p���r�~Z�}�[S�;���?O�s7�1���%i��uܵ.Ÿk�(��)����7��c�]�apW������C���9�ܝv����]��pw�G�;�(�#Ƹ�*w�T�8��]S�{�r�_�?o�=w^FƝ�W���P��w ����M`�-���_�����|�Wp����j�K�������������C*w��]-�h���]�!������=}@����U���M��ι$����=P�����;O�#�[��_'�Sq��6´Z���|P�u9x["0���暈��BY�jy�f����I��I��@���F5k�f�z�+���W�} ����T�2�{�!�{�}m��)�y���>J!ᾶ�À}x߱���U����}��!5�N3��[S	��[N-��,J�����������'��!ҍ,�a/��,m>�mVe�X�V�Z��F"�,�,�Բl���PYf��C��>+�v-�D�-U�\Gd¨9:Tp�B�*=��?�D�� ���ԝ�eD�ƃ����E���@��{|�a�=�������՗ �rO��}����ԯ�Ԇz�{�K�����иt���.�Wq�, ���K[��
ᇻڂ��E���hO���HO
�>�g�yy�UdQ�S/��U���V�Ss�V��������Su����~%+xʃ�l��d&�)O{�|􎎧u�����i>�;
O�����4L���Mw��{B��<u�pǑ�Z���[�;�'7�5�h7���^���m=O��&�?n��4�oky:,�v��"h��]D��A�n��x�m��� ���U�f�����]	pm��� ���j{� �3�v	a�KШx�8�b�l�=��d8V�������5�3!��PM��L�zL��7����St��/Ck����d��-�]2�Sd!(ע3���XS$�mљb��,:S,�֢3E��#�ZMQR����Xb�)ZA�j�MQ�[GS�B]�7�`�0�S�%-�)��;v�����8	�[�`��!���5�&`;o����q�t�� �co��p�[�ZhpKm=��<y#d�-�TB�[2O�o��r5<�G]���}pS�t⽛*O����]�釛N�3�~��7D�C��I�E����r5؜�2W���sMS{�ڜ�mΉ�*�a�.��vE�>7���z�c�,�7�
~! �y�-���^	�E~|_��z�q�~Q�X��|��҃�,��� Zb���c7�͖��JiX�	�#�D?i�_8+��-��B� ����z|\���
x��C,(ǗZ���3��2�~v����S�.�Yq�1 �*
��:�� ~������[]Ux���U��x�S�
�q<=������=�9Wy:��JGp{��i��WT�ZOc����W�<͂��W��$�hyl�G��p�.��5��l3h���!��R����(����?a�sE��1 #
��l�h�g��~����� �)���6��RF��,�I�@����M0A�?� L�I6��Q?��{jL�.B�*��m���	A��I�����M6��6����//S��`��
.kmp؃����P���WW�tY竳 /���
r�ˎ�Z!t����eAT�%��/kVU��Û����<]�����)7.iy��ȥb�4�I�t<E�zI�S0�a������ʓI�S#�L���ChxI�/�%G��]��J�p�����ħU�&O+�Og/�y��'/��
���������I�ןQ<��3������"��30p�gdw�x���
,h*�F��)Y2 �O�K��`�-�
�O�b� n��T�o�;yAl����\g3;]Y
�?�f���->���`:!ז@��Nh-�X�	;K$��������-�2ЮrB�_�'�pB%
�ˇ��;|�n�7A[�U�i�?��������������ʮ���x�W�n��b����H�v��$�<Y�XP��g���\^���"�G �KV�� �HvظWv>�s�#���<OQ�)� ���Hȓ�EK���]o��U���H��j�b�dnc|�.����2~�'���?R/$ =����5�`��X<#��?a�U����ȳ /�Q1r4��?�Fy�:#w��G���o��j�@���3�3�r?�9���C:#���!��g $�w#�AD�����I���9񐣑G!��R8nGF~�C#�&#;�a䶇FU�-$ ���sHk�?�|��Ȯ���#�ϳ�p�"�A�~���S�_���y��?p�<�'���D牆 �O����D��-�e��֕��%j �O4� ���J� ��D��S����z��	��A�}
�˃�- 0��ƃ���\���X�C��P
B�u�%t���M�+��t�[��˽Be��U*��*E�Pp ����+�&_:�����C�q	~= _:!��֗v;t�x
㡹�{4C D}/7}!���`�D]���m��h0�!�}�i0v���-��ݾ�3r#f�G�)ƛ��$�q6�&di?�����_`W�+v�׳�-��9�����^�g��]��jho�/S��� '���x,�)�� xo?7IV���X$H�K�X`v�?�^M�����$_[*���JHak���>�s�����t�p�}F���%�T\���'�	7�g�� Y#R�Kj�������ӌi�x������٧{�O�Z�-��U����}�l)�>c%D���2B��'��m/ɮ��v#���-ڻ�+͊
��q����6�Z�
O] �ܭ��&x���	��Suw�<��e�����(����>�%x�b�.�'C�������r8������Z�wiyZ l��b���t<u��.O
�<=��z���=�9;y:��JGp{n��i��;U�<��1s��������N�4	¼�Z��ӑ����7�v{h��GP��:��ށ�o�BV6��������P�?�8�Q��X� ޷C� X���8�fql�ch�S��0y�l������,h7��A]��p�q�0�/��;4G����`�r;����N��0ů�ڮ5�U`w��[����"L�A���L��Y�S0`��� oי�p��:ST\�b
#��oMQCԊGߒF��0E�߾�Mq�/�:�b/B�*}��}�
S���ݷ�Sqd�~�a��o����oa�p��jM�Xз�3Eeh���S����J~�3�C�y�(����ot�88��)������o�F1E���q4�JQ+Cc�70�}#�����q4E=��U�����S��X����gf��m3��m��6��2��۴�Hvf[�f|K��v[3��4k�n6x�6e6�@�m����t3>_��TXՍ����3�_��k݌�����g|���ζ�>�b�- �|��3�'F>�͓_ct
� WڬX��%�_���-���i�<]�����S*䟾t��Jq��K�S�m_�<m'�zł�Y_�y����K�a�Z�:��e�x�r�/u<�6��������ؤ���&��{��Cy�	<���&�����mr�i.B�*��v�&���q�T��O�b�S�&=Om��	<5���&-O^�|7��߿ �?��������À�~����/T�ު�yZ���_������y�r��<�!��R_܆!x�1�͛���ˏ�S�/�<��~�/��B�/�<�n$̶�X<���:��>�Q��J�_lTx� v���`��X����" ��(��䐍�<���J�p�Q�T	b󍚷戧�����F=O�}N��|�,�����ϋ�*�JY��>�Ek�s�?W��O_�A�ǟ+\
�A��V��4�C���Z=O���i-x���V��`�-O���c���ڀ����Tp�
O��`��F��z=��=�4\��C��F���+kyڎ�J_�v���r�߬Qy�D<������y
��k�S��hy��5����>kt<�ZM��O ?Y��t
=O#�?sx
�0n���n�W�'/(������'�Z�����(<���'��OG�<�p���M�w~���B��U��ۄOO�|�YJ!��O��<1��B5�P�B�O����=E�''��;!X��yi�Cϗ��;�� �Ax�\.�/��/	�RI) ��?�6u�(�7O,o[��
1.W,���r�]�T��؇�,�y?'�?�Gȧ�D���j8��Y�3�nM�,��9I��1b��H�cJRى�*!��ad���N�z'ٱmC�������'�4̛nt2U�l�vU`��{Ny��'�T�\�Ph0$��J����H�q(]P�z�
�� Y*N�*?)�G��M���7�]��~Rz.��Ku֊���Z d�R�Z�^*��i~R�E}�]����V,��R�Y{�����<wV��!t�2p�[���E���9���p(�.�,��3�k�DXo	�
�l\�Xo.�/�8Zoy]n�Hhl[�A�D��?�K�� !t����a=w���hf`s���!�z�;�� �u1��/��B��Xk����/.�p���Cy�b]�4
`{���?F@\���� ��w4�?B��+~@`���ހ�����l�����b�b� ?-�7�/5���.�|���e�y�G/D]��MX � .X�1p2�n�@o����B�Z{���XŜ���r��o�8k�j`�u����uw�<_�(�D�B��� *���2Q&���;N#��Rn��Du�1_��G<�Oo���T���'W��kyʛ��^�x:
��y�������S�yz��璾�<�d��d���4`7���ϡ��\O����i"�s�� ���t[��.B��Om t�+�T��sy*��Jܺ�<=�Cb��*O��Ӯ`�to���T�g�O!����i3��s��S�����4p�O���Qxj
a�l�3!/��K�]���J!�1[��'ġ�5}�/٠06h5[o�J��|6l`�Pm����0�]<����Y:�|t��
�!̞*[a8�	SkDO��U��^S��A�1U�GVx�>�Pm��
&���
+<��4Uk�;�~7k��GL:+|x�Ig�y���+|`�IČ��y
A�&���@��S{�=�,jx���Jq[�$xr��cRyZB<�x<=���t#��sc��y�Z� ;[,�AyU���� ϊ��xt��S/ cU���#��|!4��y����Ӌ
����ۗ1�'+���n�7x���i7��Ā�/!���d�YL�x
��O� ��x��)F���1*OIbY�
űH� \�����/���*_��p�)�/{-��v��W4BKL���W�/>Ɠ{C�'���a�?�Ţ/{UBW��^%��J�_�ʝLAK>����-��>��\�ps���e��@S&+�� ]�u��z�p�D�[&k-)�+��W�Nv�0��h��+� GL��J+`]'�Wܠ]~��W�|D���|��_?R|��#�+��W�B%�#Xl-��>�}e�U�|�#�U&k|e�7�+]z�#;_i�c�d�>*�Ws�H��'����+w �}T��� h�Gv������+� �d�+K������4 t�&�v�$�+�M�4�r�|�rw������o3D�1	�o-oO��I`U&���;㟉���<��X��>��&*�������Y��	�i"X�a�D����;ѱ�� !t����DATk�}'j�OO���:�<�B�g"xz9��R�<�
��b�tʧ&�x��	:�� ^=A�?�'h��'x�Dȶ	�)	2O���Np�B�*U�m�	�'w��&h~�x:�Ͽ���Ë�w>�?��@��PK�`�>t$���A{�u/~���[򋁃 ��P��-���� �xʋ�u �Pa�b`i��Ez��k���.Z�b�}�D+S0���[
*rypJ��Dn�Y�����/1p4S)j�4�t�C/�-ZJ͋��"��R;�v'%z1�D�h͋�����/��߿��W���1@|�1���Z��`|�*�(�0^WV�4^Wf^<^�� ��W+���!d�xT�����+C+�]�;V����T��Ƌ�P��p�Z�O�;�߿���t��G��SnDiy��HT�x��(Oр�F�x
<,J��] m�T�z�!drx��a��S^�(G�����J�p�|���ħ�T��O+;�߿���[��6@�=N��"`����(����]�����p�q
O� ���"x2 ��8���X
��<�
��XG�. ���	�^+x���Xͱm�i|G��c�<ͅ�gc���jy
,zl�xzʝ��x���XO.�=�*<=C��1*Oт'B|ǂ�Kn��y:
��G�� ���Z�~5F��c4�;C<u{�����)��O�C2F�S[`�)O��\i����1������G+<]pb������}��O[!�-��)�/G;�4!t�&�v�h��0��F�<�OU;����z�ނ~����֣�<�Vm�#OE�0g�B�8JC�~] ��(�(y�y/B��R����(�
�b���)ȳ�ɀg+��@�1r���� :�Ҭ0[�zZs�F�����M�	�g���zڋ�BW)�/G
X!����
��4>?L��������x���O�4L�B����T߄��i������E���?~�`卬5�*�A�O)����H�l��Y䦀�
�� ݎ�e��Ar�(�e ���"�M�wR��$ �9�˖�>�ƁA0�Pу���ȃq����BW�1n����� ��/2ō0�q���#H�yL�	�i����Q���F(o��
��Ax*�t�PG��!���~�<}�H��~��!M�ӊP=OS��4<��0-T�S`������Bu<�\5T�Ӌ��P��� d��<u�t	!C��	Cd��@>���j��UJ����L��B4�N �Z7OQ!z�އ����B�-O���	)OI����7���x���@��� �Ty:(xڊ����i-���<-��j�#OBWin'<
hy� �ۀb���t<��e���9��Px�`� ���ꜧ`�|> <��0`��S[��p��!t���� ��3�jT����c
<݆�<H�i6�>xJ��������iyJ�&�ȡ���`h��E@= �D�@M�6H�*�vA� g������~���� ��Oɞ�c?�POq�s;�����C���l3���99, }��Jcq;��0Aď�i�V�
[\��k�Z�&S$ԁ)�M�9���!lԚb&�E��3E_h�a���9Pg�j�*�(���:S<�K�:S��{_�)� N齃� �o�:��Mn�����S,����l�X���:�bB�*����������8H��ۗ������o��p�P���O���O�Z�SP��Gׂ��c�V��G�B<�i}�|�7�i<B��OC D��y�9\΢�����������!��QyJ#���O%�8�y��}��w�*[�tr��N�U������p%V�<�<g%z|���f�j�L�'�C��-�ˑ@��>i
�9"AO:序Y�K~&�/��R�S���6D8���
'U 8�}�������̀<����`��#�@W�g��{Opz��=��#�sj�������j��~�������l�{�k����"��&j���+������޺f �7��޺f��,��|���������_
��a�8��e��yFo�f !t�z�v`oa����|��L�LѰ��9�ڠ7���bo���Eث^E� �?s�����tÒ� /���!_�R�_ `s/��il5��6JI�~R$ WJ���-�ge���֧��K!���͡@	��|!�쥭����{�m|��ǲCp�}8��&z4���$}��b�m�������k�1���驯-oE�ޞ�	o��D�������X����Z
�:� 
�<�]�g�M�;��+<O*�蘆�J\G̬AhݑϬ�$o��:*�*�;ioޡ�r{�I�;P���;b�u��w�����`;Ys��y��Z�
���oGO���B�>��/j�@�8Ę���0�������+.镡_��B�=?ҟ�E��*���#�:��u �0ζu$�K��j�����
�q �ʤO�<��间�ǵ֐>�	R���V!��Nm5��陥����u �y�Q�-H�
��o9���6
�=߲#=���8��AmIo���mҫh�F!����L��5ɮmHגnl�!�5��R
�]n������ҍ�Q�@���v����!ƚ���'CX�Z��պ�u�' ]���͠߾�R���3�E�O�> R�ܠV��������x���?k�08�� K+�A��9�JIr���4C7���^#�SU5���Q�e����Q+�{�5�û��JYh�H� u�P����� �Th�Vr�Rr�Vʠ/�ÇX4�'{G{��$�ޒ4�j������.B�ْSӞu7X~8 xp+e���$-��~bɁ�o��������ň��.?�aMD*3Z���P�S[b1ݕ/��wI�Sߖv�4��?! �i�/IKm=.�RK٥����7M�js���JH�X��B~u�]��G6�	��|�m�o+��)�f��|����
~j+���K佥L��������'l��=/�<���m@�4�>��������@�h�4
�G욄#�)4���X��r�)�U�B�
ķZ���f�5#לь�����6G_��=Ϛk;�K�n5w�t;D_AqOs����o��5wtʏ�\)�p s�������o��\��#�����t*�_N([�������e�_�9�9o��h�m{��q�S�cYe����ef�F�'#ƙfJw6�jr��2�Ѩc�65�N��PM�JS�@~��e���fE����Lm�R�⇢e���"�jɏGÜQ_m�=�b���)��T(��������M[ƃIiZD˸Aۚ�-�bA>%�2�Q�!¦ɏG�v}��ኹһP�@VDnD>/�-c-�4U��8a	Th�q��|�#�	�ؚ(Nx��&|�#O��V�0zS����
5`_��D�\��]'�|�)�T��h�3�p��5��+����t�G�- =�5̒v{�C+yP
oě�0'K��L�qL�(�B��B��;#�F4�Y+�&�g�t�1��Ac^��� 2kַVP����
�]U��º�v�`s�:���=���'��4D����U��X�"�`�G��akB�IU���W`�!I%�W�*O&{��{���&,$�ܩ���`$�0�^k�X�S&������xs��+�������"q,y}��x=n%���P7]�g�7X�a����!���Y)��O3��VH���ݩw�{��{V���*��Ӝ��@�oU�ڑ�Qݩ�����)ȧ~6 �F�ũ�x��TQL3��*򩟑�'U)��O�3?��*�)
��Vv0��JP����b1�!B�*)I��Y%����9��.���掗�@gK%��C=x;K*)�:i< ����`��8��-u�ܯҿ���d໹U�9�b�$wޕ�E�/�B%N�����J���n���/+���9�/vs3+���/��./�P+ n�Rws�ɟ�φ?��r8�1�!�4 �h/m_���^�}!k*��ܝ�O=I����-��UE�ݼ��Br**�� ���� ~�� BR**�++�h-ΞI+������e��4�#��q�c*:�,z*:�Y m-��%[�4��A=
��J�(�LN�C'�]�������Xw^=��pȣ!�Z��B<��ƿ �
s��`m�e�An �ο �4 ��b,�-�t��H^L�2�`�_F�{�2�n{�n��v,��������]aS-�Ӂ-,S$��u?���ae4N~�����5 7.��������J�TF��Tm�~\Z�n��<���Ҋ� �VZ�C_�ܸ��F��4L�§�eM�_���#BWi n��f�qpi����
�܅�.-[�p��
��Ni���֎i^�"̙g��=;4����[���֖�_9{v<���E�t��!q����gx�9׎g#L�λQh���
�������b�#�#X��G���©�Sm�킥Y�ێ?�ɔ:L�O��o�ա�/˟���,�G��D��x��\��FzVu�L�-6�Ol�>�M��z�1E�{��N�+l&����������2h݃7�99t�	�kN�̞���0iP��e��I� �晞ׯc÷�$)i��]XX�K���d�.��F�C���0��=����.tEJ��T-!t1�NUr���驾��
�R1,?9��S�^�.:�����V�C�&�¶R8E1z&����Yr1���?)���E6��K0��a�-d$�
�DY4�CJ��#��Ѥ;nN���2ä����5���F�d�K��$�LR@�h'w8º��~F؍����2���@�9�f�d��={0��Fņx[��j	<�$����0��H(�S]fo��wB��'�L���B)M`)1'����w�S	���-��0w�0��=��U�n��k�
�x���C���Q��C��޻)9��k��ѥ�V 1^|�����U$ķ(�W"�lZ2��Z�N'���H�rd/�"=3 ���T)3 �g�Z-�3V��߱����o
�НDA�8��,��۲��Q9+��P��L����E@�#�T"#�r?��M�*K��l���q&��t��3�1k�yt�M׀<*�Q0��r�=��u��mQKI囜S���d�"g�h��X6��!(�s@.�ɢbZȭ��m�b��M[��;��U-mu&�a�6�c�TK���!�C��M�Y�C� ���h��9�7�JaF�����QL��:�}$Z���]R���ۅ�?ΐ�����r�0�TT�y����N���æ�T�)0Ά��Pk
���sV��0�z�Z˥k���Q��Hͼ�i�l��Nt�%񬜁�̩'��5^��?��,�EmF�,����<����&��+����������Di��i�2��6�/�Z��.0?�����y�Ϫ�5%""򴦣�D`� ���G+cF�iF|
��W��G�*��d�|,�[1�X���S�5�Nis�S�[+Y��8ot���2Ȭ��m7�1����t? ?q���+7i�VRcG�p�WBv�$Rsi�W@�����5���
ĺ	V�3���Q��c�
�?v�����QR��I'����o�eތ���)n�L�)����ɰ�M`�a�i/��J����[��h����������� D`����$��e�I+�)iy"�n�� :Z0L�b��!MFV��	�<n�S�pkf��ǝ4�0U�*k�Jle�D�g�%'<�qƓ������[n/���L%g�<:�D�4
�i1UT5�H�S�
=Vb���	�Wˇ���jA&�E�5�'��6�d��Ѯ��,��j����3&i�@�J6��!5D�K`oVKh�T7^������Y�F�5Ii�mJEc��V�u�c��.3�΋�*�b:�ڥq�C4H� �w�iE�hL��l��wL˴x|��6��F��451�x'��p_2Zkx'�2����	N�#h0���#�6Ir��!1��
��P4Z�|E*��h�~��&��B��̝��=RO�Y�����%�1vk�B��{�Y+E�怶��e
;����s̼A��EK��f��ıMñMd=���1���a[I��1�6�e�ش\Vf<�&G.&G��Ynғ8�-^��#
�cJAI�Ɏ��ؔ�I9�|�I��&�߈%$mRJ����ܯQb�D���>��tޓzbOZ�B�;7c3���z{�Eub��1'|��H#V\�l�գ1F�d)�ɱw�%�?K0���J	�lԗ t�(sn��Q�_���\���%<i�j�T��rkS:T���J�$�k%W���V���J�f՜�%��[S����$ʦ㏞�%@-�Jne�q�{�X��6Qέ�1�Q���:������۷4�-[Tn�7��jٍ�moO��:X�UbEB��u�Kb""b()aA,��i��yX����Z4�T]��YR��9��"i�u^��|!��<J/$� Y�Y��h��bzw/�w���NXD�1��g,yĴ�0L�P�n��c1�3�.���
>T�b�Tֆ�k�iYk�� ����Pj�o��T���1<'�*�zJ�PE��ތ��T䑅�Uo���~�5��wc��,�H�Ṥԓ���ŉ�^�L-��I����0b[z5�&OŖ?���*]�x������������V娌)|�3/���s�|�!��"��� �3z���,��o�J�A�N��&�6�ۓج���Lҵ`"��)��j@�Q�=��j]V_;9f5�_�z��>����vy͢��q����c�JeM"���9��iN$d��-AR�?w��D�W�%��r[���̥kt�Xj�ZS��ю��j�V1��!%fP��S.�"�3�4TS,�`^-DLy��/Q�c�J-���a=�Z�՘Z�i������6��&�RdI[d�+�"R�����c�4V�*r��(�{Q��{�9ΘY���-�(W[ B�e�$�o2��f���G�r2��8s)�#j�rf@����U��j+Vӫ�zMCPj�l4d�n�u5c�hϐ�\kK�b ��j"r*��J�T�>I]�0q��ܷ��<��ͭN�ը��f�d�0#sa�y�9�^*�������v
��B���T�[u1s�;y
-����nCVm8y�Zؓ\K14���{2b�1|S���$��,����cQ�66M4��76�������|~����!#�U�F#�ñV�?��%�P#��!��,�T
��'��!���/b��df	�)Z�R!v��lO�4f����VR��|���bۓ¦��U=����]�؎,X]�9]ՀW/��+���>V�ќ�B����Uϴ�a5%?�N���*Y@n����K�]{C�Y�yyO��]�*V1sYt���*vMY���ϸ2�@k��j�Q���!�И�;��,��8#�ʹ�C�j�w�X
�rC�*����m�|$����K��b��:{"k2�"�R�mx�v��=u�-[���U��%>�?E5��LhY�'��SjjKx�4_T�;Q�9���4:˳:�re�O
�K�1eqB�o�ӄİ�.(��j:���Ek�G>V�P��Z�O�_|,!Þ��3?>�o�d�Y]X�<���b>O��~����Wg���	�V��4ln�Ț56	fȺ�v�z��E���-�M�N ����Y^�c���?����#�o�D9-����!]�i0lwb��X�BL�C3C�m0��hD��n��8�Ja�K��Py�'$YL5�s��!r�a��3���u1=3�v�<���c�r+��	jq���������t�U�!�<O;�� ��1�e5�+�-�BQK�,u�@Ok@`�W%��Q���lvS����O�3��x��N�A���	�=�L��������S�cX��^����w��ei�n��WK>�gM�U�w~���|��ȴ�(�R�D����W�7���&8�%�V�,�O�1����f�4Z��`�P���Yzb"����u�d�}��ڐƳ�N����x����'�}œIx���H����ዝ�<�aӛ�$�s�>j����A�.�	�R9�9ʓYY:1�n�F�z_��n�?��Dh=~{yx|��Z���=�u��}����Q�kA�1Ǎ�}���UfDҁ��V/�T��]o��ki1 �!�v.g�ؓ3Z��cc㱊�V��J���Na!嘾�A/���Q�n�.NY�1f¥o�K�h9�<����n�u��6'q@��:oƬ;�j5ѣB.[f��!�wtތ�ղQ�7O��%�ƛf�aWՕ�kc�]�=,0������k���l��gX��{�m�C������J����������������~�}f(V������χ�A6�����M��yt�Cvq� �C�ɩ��u;��sSt��8��ˈ�R�:�(���d�n<?W�g�ܠ����2Xy�e�N���y�T���O���|>1}���v���>'g��R��d�_�f�P3�L|�idn���G9�6����|�#��5ݴUBm>Z ���ҩ��w^�:s�l�#�,Ӭl��`ZH��]�_	����dt���u"�LXiƗ�!I��J��(843rI�F�����g����?���XMg�f	���2Sǿ)9�wf���Ж����>%���$
IEd<��3�!��?��'>�P[�T��)N���NF����ѡ��Q+��7N[Y-UBn���Y�ڊ�}��:����1�t��<-��)��D�E���tն��)���fS�V��DI�O�M�!�m�K�n�w� W(�� wjOK��N�T�'z�4gy�} /:����.��؜]>��=��2V��D
�Ǔxp�xw���+c�����9Mqr�F�}��ȲF.2�c!K˅�p�
����B-��yg����t����2�I��梬'���`>Z��B����
�{iQv�_��k��%���Da�^B���̜Jj�+�poF+�s�2�/\��"
�W�"w���p��4�Nx1�\f�z!�5�)��q��d7w�������8�Ue���jQ}�Z���\�l���F89�	/LUY���):�ib���Y�>�͒�Ü�8OGM�;��A;Fb:F�P�v�P������_�y=��e×���uЫD6��ݙoO��,j��&w/XM��~΢tr[���qX�@'��)��Z�`�)Q��M�륤�/N;�z%u/\�!5=u��r�����43�'�#�"��"_p�"1
-ɩ�tͱ
F#�4��}6e�r�s�ХE`��ƨ�����P��ٌLy�����A��j��FM��o:���r)�osؔ�cq9��+�ͬH�%���IFw�l�Y� �dYj�N����{N6c���nX���fgs�F�g<阇}r�+${��b�	'ץ���z^N>���uī^d fE�8Y|y�h&���4�2��3͎�B�Lp�3֯�5��L[�A�D�Eb�-��dU�4�X����zq�c�"O�f�Ⱥ�X<��k{k����O�0���7õ=^���J��qب��+���su�%K��V
��k�D�����v����ϱ�w�)���`'_�Mɷ���ڥd���$R*���iR*5��cJ�v)��JS�^B�t�V�EJ�x�~pL)y�}��~�S:6)�L�V������m�P�i���?���%��[	1�dަ(�(O%�.������ˣ�ƅ�v�x�Z'�}�ۧ@�|L���c�)W8��G��ڌ	)q���9�:ӈ
k�۩I^2T;���Չ+��zv�����ͩ�ߟ�K­��%���f9�V73�6�j|�]�r�g�hȚaz�N�˅b2gt��7>��ivO��g��P�G�kx=-�:����Y���Y��i���M�8�?B]�G���FGI�'h���G�G�9<*ח���WZTgO�X����-:/#�0��?���;|F�f���3��9XDR�B��'���s���E�iܽ��֞���۝������2$���ol��Qԩk�r���ƌԜK��cD�Ctc\e$t�2�Wmn�PlW���FqZ+CVf�?_ΈTOz�>8�yTV��;.^<�4����=�ɡ��̐|s��I��ٮ���dc��B��(����hzfi�ѭ�6}��sv�Ͱ�Ǯ拭R���e���ⅱ�J��?�����.�^�)3��n���lm�%c(o+�о	������X�5�׏PFʲ��ʵ�E�[j����5\��v�֔�H9��T�k�S����`���1o~�3���wVW��h�<��yX~P���	�B��T�V���p}N<����L9�+��K�?&��]��>"���.�:������)�Ϝ��6����K�����������a�\�h~J���Ns����Y�cK��YT�����Z��{�F˴.P�"���Ml�
.]��P&C$���ϔ���b�c|y`��l�z���E�c�E����t��L����H�F8�Y�M��2Q��t����{-ܠ��//?Jb	��b!����+0e�|řM��S�$��<��l����|�A�����Ub�Fz}2!�	��!�Ue�Կ�zR���3Y�4�k~�J��>��&���$ޫ���Lt�6�(64�����r�ܖ�o�DgϜ�B�2�Q�
�7s6洉~�K~�J0�̹�n�ղV���zR�3�ϋ6;�f��L�=DzUpSL���8�+��%B����S%֥d������7�i�i)�+R:�o������6�F'6���DԱ#�;�1��=[���I���#�K86�΅����n���;�o�
{��K�7��r�Z+���>G�t�-[�.ܗ{C}����c��������L�
�
�c��&��%
I�K`�����
����
'jXV/�Ͷ<�b<��xܮ;��h���)R�ez���0m�C�<;���z������+�sI��"?Ώ2����J�kF���r�a���8��-rLߐ��
�w����"^l/^#��q�t['�k�"ݸ�T\�O	����Y�<c9�x�.&k�m?��v�q�5��H��R[��H�!m�?�������Y?�,4�o������!��L�H��t�Z�n�?2��k'yy ��K/���we��� ��&��W��6_J�v����ѽ;iO
�i	���w1͞R���L�%{��^�����0zC#���1��P����}�g�<�Z�h�7C��蝒�d��b>E���N�S�V�q�EkD�Ha�)�0h�X���J�L�z�S/��Ӝ�
���)�q{:����l�Ccb$�>GM�f��¸2��6�D��1�~�k~!�
��2�5%���hS�h�`i|[>�)?�Ⱦ�x �i� ��|�V��]�G1�n%>�G�\m�B��\sk�,1��S���qI����ie�U��<��o�3��O�*O�i�>�,�u���W������l�}3�=^��l2�1���H���مx�./�
Rz�?Ѯ ���8 �ݢ.0��Ώ�f��,RDkq��:k�����Z��[kh7�[��Zt�R�⼕�>`d��s�s�	sL��^�b��I	̶�4~F	�ڷ��y#�IhXf��)1� 3�����l�w>#�?m�(��w��|-���g���lĨ�WY�+FJ�%�����������8B
f��,��0�A�����22�C���)ln�
�PV�~5��jk@��3w�|�#�{<m��Z�FƠ	��'%I'��D���r�cV߽��S)
�6��'�>?Cƾle����$�̈��t���������3>Rp�2��q�2F��&8��x$\u�saJ?�%�3�u��d5K����D4q5��� �t�^�$�Eft�ڙO)�Ґ��1� ���7@�A�]ʅ��A5��*Ժ�Q�r�uc�n����X�
=��	����lN�^`��O�˃�2�x����nq4g��
�J����,C��
��aǟo�\��7F�e��9͑��;��5����$��|�}�5N��W�v�q�r�C�1��!�PO9y�@~�C����"H�]�T��Q�X�&�4Ю�);�I�ϊ�8��/���Y�4���UZ��T��e�.xclU}햱f���9�C�Xq���bRgu���v`�8��|a�O�6�/�x��xK��`��X���q`<��bQJ�2Zd�+�6?Q�~��%��r�5�ϱX�����a������hf2�)�
��7��"&�
���<�h^^*��E>�����1�>L�̯I�b*���1ӳN|(=��l�i�,�s���W
Y�,�������B�^�E }�'�չ��2��k�����Vi4��
3kf�Lm���,)�H�օ>���@�8b���a�)�h	�>@�{>��"�S�=�mȴ��P�;�Q!#���ő��(���bMi���2#k���Y���pՃ��0��_��C�U�\l����~��?-%�Y�T?_Ţ._y�?Zw�U=ǿ�Gj��u�����l%�
}������;�5@6n�g���0�>�љ>�7��}�)E4lm��w��/��̊3o/�Ӵ����|������k#`0K+5=Ŧ��JS�
���Ғ���33Ķ��O+iZ���To��p�l[I�� �z������@2'�h��Z66G܈�p�m�mc� ��K�a���������G���m*-N���v�����0~�'6�:�e��x�߄��:l⇿D+��_�Rvut���|���^�����N�ȵ��A�ʕ543r_X#'�*�9��]>+�.Yq����>�i��<"v
�q���_�$��~a4p��eӵ)�#"��o��m��wI��$�ؾex��n�:H͊���� g�A�;�ÙSP�O�Ĝ�.Ve���X1NbR0��&����<%_*B��X�6�#�Kwzw�>�N�4

J����t�K8Q!6�̣S�C�����lB�\
r�vNW�m�hK{�N�$ZN�WZ���V���Zj|ij|	�@e^t}�P2J�Z�0���c�X���F�]�VD�S��b�=ﱁ��t����m�T㴅H�WYJR)#��27����F�L�Wy��Uq݋�VF�ҫ����t���n��$�0�z(�>��G��uU�\zY�m^Jd�L)b���b%�������*
����E���:e�S\?%��J��q	����U,�?KY��W��?��e�C�)M0�Mz��r�~~��NJH	��۠�DZa �R\߲\R.���j�� ^:ʠ��|eSOj�oUOʎ�Q0�OȢ��y�؃<���Ǉ0�3C�C�4_�ghs0�Ny�A�v��c\.�!�ӑp$�6:L�{�k�;:�	�5��8����y�,9��7�f%Z`��G�B,#�Ӓ�Æ�Uo�#��1e�B��Y
L
\պ�	+��sr}(gt���8c<ed�l%���Fp�"0���Sg���+��8>��\��<�$[���R�ʍ-Ǿx�Y.؋gA��hu�­\����KќҫA�ϸH��Z�³��͐tB���HO��U܁&������uxG��JC:�[jb%��J?u�ȷT!���CX���4��M)�jA9f�@K2@���9yO�R����
��KP�]F�V�Q� :�P:=
�p�a(�:�*��0u,�=�l>#�Sw�˃8?�ԖPOo^�$����O�a1&P��<�ThDk��mߋ��T�����AIJ�I|]�7�����v��e���2N�՘T�)/t;;��,�q�W���?I)b�I�0M<�6Ł�SV�q/�q����c�fB1*�+{�Y��Ę�l�RV7ј����	�=�� ���j�h��0@�C��i��O�_R���.�F���r56Fn�	vbO�A?ўv�N�b��}��#]~x	u�[�9��.ػ����*�VyGw���\6	�h��o�N������~�ǭ�7\Co�����m��x��"N�X��Dl[w�/PO2������GO�C�`��=�b����M9gJOs���������k����Xc�ն�o&��s��no�/m��I~l6i9w-���l���Є�}@�9�&]֟���E�����Q�B0���V&�ʾ�͖�'~��rH��c�e�:��B�5{�|�R���r]�`CG
�Lݬ��3݁O6,�9�;��j��Uʽ�2���4�o/���|Dӧ��D�Z��Gjg ��nd�]�H�5
m�D�5�^|�~���-�B�4��`�Q4�PC�������L���-��x�0�R�Z��;����u�x-�5�&Ad��U���ݠ<�W�b��<w�c�?�� e;�϶�0[Y�l���
"�f���6$l0��`x,TB|@��@nz���nC0�a,�F)�V���sX̬JXLkc��
�43�]'�QV��U���f�&��iF�����=�aw[��R����H=Ԇxc�/�T��8Y���*C��eki x�g��Y���8�����������uKh&�֎�\��ƃU�¤r�VlCxn9��;c������z{������z� ����"�4M^B3}
;]
��n�d�d��ɋ��_C�� ´vP�4#�clSQ7X(m
ih���I��rV#%���c�Z�R�,��Ox���P�R��>�2��F��RG5��:�X�Bh]��k����t,�ܐ���{��x
$$o���F��?{��o�J��v��	�ɐ�[?�i�e�Y��O�
d�
�M����Z<;[��Z�<����8�L�h�fTK,2FP����O>�V`�:?���=DFU(-ڄch�3z!��}?�H�׷8���!���X�ȡ��6��%	���1Zs�coEǜ�}�(��W9k��2���;�[?������KB��G4S�?�/X���:��7u�������5h�!�/�2�rS�E�a�C'Q��Zb { E)��?�&NT���f�>δ��x5�d����S�F�I��z�c��`��CW�v�7PM��EWtl$#�	��
Ws	�hx��qN�;jn�h5UIP�лJ�����R��)c�㘧HKlMwx�n3�uj35)^�{�}����>B�N���K�e�h;(!% �E�=k+ۊ�W�Q/Mh
|���ֿޣ���-:�3����Z~M���EtvO�6^�ʹ�U,�t���IM>�07�
=RK-��V�zj1��\���(��S��]vhv�{�����ʷ��r��.U3}**U�s��:sʅ+�*�jJ�h�j�b��F����Ҿ��A�a�T��J��ϲ�g�q.��]���_(��ϱB�׫.{>�����K��c#	��\�\��,���1���:�p1��1�L�&#wP�
C�P�*�r���_�Ĳ�5�K� �Į��O�Ĕ�V�N8��7�O��I5x�_6�v�UB9�H�N��#v0�,��u���1~ L�)��N�sF�� ����p��&� �ЉcZ�*�b��W�P�-�CK���-�ۺ'���xjAR!:U���(/�l��c�lwt��T�v�q0f�'P�r��_���I������N�W�/ҿ�^�j�<P�{%6�Т�gWP8�=J"�0�j�uF�n%�0;x�����4a����ߪ�-���|h­��g�ߏ��nU�n�Y�/�YhF������P`h�� ���U�ր8m�L*ꙑ�ez:9��`
I��/����7�E�&�Z�s��48�	���COFߥh�T��rڥ�	
=XV,E��9�~*�l�S�|���:��zbƎ�@ܬ"��ϖo�Ǡ}f��Ǳ�A��!�e�>�5ڇ�1�
l�887�A㴪�8��k6N��J�4�o�8�J}��U�ԁ���VI6���_7�3j$����k䧼����N�[8�em-\���E!!{ٙ��Y�vrW�JW���(_k)4h�2�
{_�����d��d���l���*��x�a+�R��p�?n��V@kU:��H���/�Ȼ�ŰJdwE��H�+Z�Q�=F����Z�ߤOd^�7N�4__UI�Y�� Y��
m71�A���wM;�ޭ>�>xZ�8�0��^��~���2���"���?5px����s�����hy������M�>!�9e�L)jn⭩Xǣv�`W[T"$�z�!���kÍ�>���>�Y.�E�q�6�*<��% V�NS�i!���R#S�7��T*$>���GʮB�k���B��P��/g��Rk�s�R#�$�E����7t�q9�69-�Ԣ�B�ʾ�5gk0ͽ#�=�1-Fϣ�ͯ.��fhgp�0`�����'��� >�՜�5r�,��L�=��eT`fa\��UP�[��fx��k��xrL�k�Z�g����X}�F�e;�2�Gk�Ā�PG$VZ��[h�c��DZA��4�J�����sI���TJ\V�s��w�U||u%M��Hi�[)�h;�-�q�T�7���$����
t�  }�`OV)ߌ���>��6�7����Ak
t�E({�����	-Z�����o(6�
���� ֐f�x~z���t�G��?���)U����X�3�n��� mo�ٽ�#��*fk.h��	8�����cP��ts%�zY^hR�b�	΀�]H������O����U5*��Wè�����-핱�q�����8�5֘�е��A���-BޯԸ�Q#��5h!�X��jR�F�M��'6B���F`9����h�+�h��B|i�%��q�
���1�����8_{�v�;T�� �Ci��E�XK,��i;W���������G�+�g�Vw���|��a��#��8�yJӪ���x@�c$F�9����=��V�м?�Ӌt�ҵ�N�'��hC�����nW��G��3�ۆ�8�Vc֑°n�@�h��f��]��I��Ì��-�6['������nU������7SIl��]y,���P�/�#�����qq#�׉���0ѡnqs���;�r����0-�_}���-=	���ݯj�y���4�j]���AtG��-�G.�����咂��o�����݂�n�{M�~�[K�?���*�A[@Z#G@���>V^�;��y����/ȇmt���1ܢ�:Qq
��m����MLg@!�����@�������si��1_��bx���9����C�2�h��d�{j �`�0�Ov�����]���y{�öi��h�I����h ��8=ve�K��X[���|L���k�[�"�o����"�AzG.J�^Д��D1v�����Cg"��r����/z�
�͎���]F�/�t��c��՗��ThfM߳�{&}Ϡ��Q�%Th�����<�)�@.�@�2닧cqi�R��^u(���h'��V��4��H��j�7[�e�:���֨�c������{���)���\�����%���G �ۻc'E��2����Y���3Иf����5�:_��7�~�A�Dʁv�ͨ��K���K�/'Z�
&x��{�kIg�v*�y�S�QJSc��f����Z�S�gb��O���@�TW�
*�6�&_^��/��.J7��bN�	H��ُ�*�X�Ki�
��7�%�4j}������3�����:�Q) y�Y�T�W�Q#�M�-<5�Ol��@95�9J7k�M)u�J.����2�J�d�l�L2��Tu*�}�]��M��Rz1!S��n����ɦFq}i����x�qCcc��)��������?Bu��g��Y 0���� �/��������{��4��
�u��gj�	<s��W�S��>ZEW����^��B@*���+Gm���ZSGc�{�{�4x� �,��*��0J
�L�c�g�>P��mh!�T�$�<��;�Nj�;���)J���4��fz�Izh�:�  U���DiAuŶ���9#�Bsx�IVʦ�p�W�^�S�8A�:�)�p&���(U�y�w"��1��v"�@�:{�Vr�L�"Jx|SBsl[�o�1�.7�j#��qbj���>��)b���T`Nh�Ͷ�%�
�n�6�Hy!���]�`���*�(7�52��1SԬ~�=}hv��
*�v"t,�3%�����}�X%�E2i<�'�)ȓ&�f(ﴞi�Zh�rO�6'-0<ww�U��]ˑ��>Pi�U򹔳�
��˔��'o�Ǖ���!��L�U6�vb'��Y�K��%��P���T���H'^���n�P�T��i ��Y�@��nK�gֲ��TdW䭼��a�Ki��T7f�R/�d�<ڦ�J4��ШҦ����*���Gp�ߥ�.s���S;� ���eP'g���!��Y����HQ��5&��R�*�,Դ��X�t�(���K[D�|,���X���r������T���@�/��z�3Z���L�K���]ˮE�Ϫ"�_�.ǳh9~��'�؀���,��Zy��aZ
5ER�[i
(YiX4�e�����2��&!, �[S��kJ]c���������0k���^��L�n9S��%5�9��r����]��|-(�ØZ9�T���J'��Blu�kۧ�5��q��{���_�Ks�ؤ�)b�5�Bl3ޢS&xjx�:��h����?(��O:�-���B��o^�5멇>�F��o��aii�hze})�L"�ˑ��j�
����}�ׂ7�	���R�J!	Y��`X���N �M*�1Q�V@��h�9���MWs�(���>��m��ϫHE@b�%G`Q����
����]'Nh��!�"�����i�dN�| ��g�+Dj�ҵy�,�4��Xkf	�!]�0��J9�֍�zAl�X���'�/���SMAR�)�p�j߯�f�����z`���L�ԴM��N�j��h�Z����YҭS.�nh�X��Q>�ئبɗ�6IO�R~�$7J(�H�j�  B _n�i厦�R]�����"֠g�7&-A��_i�̜�&��(�*�}x��T7���6ځ���1"@�)����*m�c�ؒ���1NR.U��}�#n��%1�|*f�N� ��W�{@�+
x��a��Q#4M��Y oV�>�o̾�l�L2�������s��<5�Ս!:�������^��<H|��D��[.li��[\�4'#˃9���&p�����Z�B4yN���H%�1��lL���y����{�:Hh��j����7�3Q�2
���!�g� |�z��{4�r�_����'� #�T�BХ,ӆ�'#�|��[��B��TWm�	�J׷�����e�*<@=Ҙ椙�h�.i���\m�A� �������]!����T%�%&7o��m.�`��g�-����T׼4�+�(�CyOSѹ��hQ0]�h^0E'}\z�C-�'����K���]�y��_�!ƻ(;F�����5��>Y+�`v�^���C�V�Ҧ���Mҩ�/�g-�Za����qg~�|/����tI*��Q&5��KRI�y(�0���67���D���(�U&��&��43S��b�4~s�DP����Z�Ub��ј~�Y}��_�?�w
�R�ޅH��t�E9w� 3>pdz�q�â���VU^��ظ_!�4t;4 $0,g����<�(u�p��=���å��A���ir�Y��"=u?��^���Z�vkm������f�,F�(���<7IE�{�F~0ħ*RQ�METm�a`S�oJ�~�b��iCwtO�z�k�x�� �m����o��M����V�B�r1�ۤ�Z[��JGV
�B��MQ9r�]Lu-�n󡴨XT�ħ>��U�}�/Ľ�M_
QPe|Ij<м�Z�C�T@w��n*`��y��S\�McR���5y���b����׼r^S0��@b��r�"�dX� {�]P��ůP[��k���1�h��LM��X'�A�Mb��3aE�����N�4��"@bs~�J?k(ScR���-}�_L-�bkLK�Y��)��dM^�A�θ��i�.���<�F�oFq��4֖�k��y08�M,K�!5�&�לr ? dR�S��HFL�R��VX���^����>��I��{j���[�J?sa�h�Iq�a.h ,���!��Ʌ�H+ӔH�@ݼ�)�LT���д�����*��	O������o���yA����:�(�I����E}M�
PpkJ�Qta�r�����`y�>7�i+�pE��$&U��Ȟk��`�%Wt{���b1mDb�+J�ꇌ��j�	)���sU{b����q�>}<h�4d��l�߃]Tl�>d�,�3�(����Ғ�`��46�n���G����"z>2�ʻ�y����c�!���h�eE���0]B$�ر�3�j�L�Mֻ;�����B�i�e萣�==O�J��V�=�ڣ��8�;;t�N٭S��
�m�ͻ���yg[P�Z�NA>�u�0耈��`=+�s�{���<"h��4_����hK0�r�Ӽό�R<W�� jXΚ���,S��ξ�����Y� �������)ςTL�r6�a�EA|���h��6����]w2�O����X�4�����s �K�4�LCF���@��U&2 ?�����0�73��Vk��Y��P��[�� �90�iZ�k�R��hZ@N<�I�^���6iZPO@}u3/�Ը��Tr�#�*����`�rT;1�L\@OG������0�_T6i��	�~d�h�<u�	��������6&���ɍ�^zQ�]�:Q��,4�k�<-�(�I-��ZK?N�R�w{�bh~2 ���~Κ}�:�Dq僜g�9OMM��Y��}��^�]��S"s�z�YЏ	
~��Ǉ_o�y�o������7~�'������~��3����o���7~Q��1p�q�8���q �H}�	�- .���%$:4$6��1dR�$.zR-> &(x|\�����#Ə�9�찱!Q�5aD��D�F׌�J�ntl��Ę���Cb��#k6
�@=��Yl`�����Y@p�o��%��Yd|�o��E��(P�>Gmm��gA�k�9�VXT��jo瀸��Zk�X;@g����k�4��5��F|D@Tи�x
�f�ظ����Z`�Ƅ��a׈2�6^SK����O���TKY��@׵�%���S��Q������p �k�O�Z�V#.4,(�������@���26 2��>[��F����������W[���
�F\`����k+K ]��e�$D�VOĿj�#�q�!115�#01��>B�_���5����p��B[�8!��Ւ�]K:v�t������o��WΈ���M���k��aQA�����e�	�~Skz��-�6���a��8��Ղ�����1�Ǉ����8}-����8��>QK}�W�.Ą�F���.�a��%��1~|�� �QS>�
���2(�Ūԁ���'9���۶��>�Wm���X]���+<�ڻq�.�0.EN�QN�U��8L����Lt�Zy�_��_�3(������*������?.$����|�@}���O��]>�r��������r�.��~A���/�
k�wsr�����@��n�N���儘����O��o�U����O�'ʧ����!�5Y�IU�\���}th�Cd����[{|t���q���TJ��q�5�Qд@�9��]m��}W�3B���Q��GB�j�Ck�U�	�3��S-aa�L�A�a�a|�`r�2!�����6�����a�h����x�)�JZl7a��Wޏ5��2��e>���8�az�� �az6���Ʈ��0vH|�q�=�T{�l` t�8]�a\Db�ô��> 
��ZOl�C?�L�|�`��P�=��5�ur-q�Z����V:.<�����U�ݸj�W
�qb�ʮ
��/h{w��C��8�����2֐α=���CT���CT���,l���gH���3����Y`�o��$P�&U-c@\�;;���X�p|�~��8���Cm��>
�IA��8�_����kG�>����0�`���@����4+e��H7��Csrp
�Ȉrp��rp�?AU���������)�4�n��?NO����u{p읢��(���D��k
V����|�(8�é�Vg���MR�y�~O:~&r�Hz�a�n3"���7I�s�S�P�n$��1�(�3d!�C����7{.Z�����ې�۰i���fm�ޑ�Q�}3�v�<g��:r��S�fS�����f�)�xB}����'u�m����t�>]��}�!F�c~���F�Ȳ�[{�7""�u#�~����t�,��WW��Xl���7{?�8��8oɪ+Z)X]��_����ʏ��d�|�i���Y�U�~�;$dɢSN��q=D=Цm�3K�_b��uh������1cC���1t�u�u�1�:`=���`,�E�������M��~n����ȡ���N#�EG��[�~�`�AC��ns}߼�]��vuJL7I?�t���\|l�,���Y_���:�c�vc�>�:��-�S25�X���7������1c�A��cB�0���w�{�>���W���\��&�s����ؐ8�Qq!��CL֧�
�8��%�7��6Ti'P�qCM4�
7S�lf�5 ~�	��}_d�:�5�}�����Q����O���t��A߯��|�oԘ������>�������P�?��{�����P�vp��G���p�����K���u_ ���?���G
a�a�5���B�z$�B_?+�� >����P/����P�`�!\�!\�`1!��`��4f
����(�pc��\���:�p�|�!��p�B�aH:�B�Rk(���,�ˡ� ܽ��[+�. ���ט�z
�B�k@�N�p!�t�Bx�&���[P^m�By!�{�B}�B�p��.�.��By!���B�g����c���'P^;>��B��9�����!�\�ܡ��7 � B�w�����p���� �A��#����g(/��K��ʾ \��\OcVF����;�������'��0��B��Ȉ��Ĉ5�<3#�u�X6��g�2��E}#��!@��F�\oX��A؆e�Za��k:�dS�a���/��m�X�nk�bA����U���d�ʃ0�ވ�	�.F�]��f�J��mw#�$G�xv�@� �Ń�A�%��AxThTmL�D��$�9��Caw���7W]�?�Yw�5�G�z$~#���Э��!u�n»<�yE��'n��MK�7&S.]�d����9J�Qa92�o�e�t=�GZ�t�:��2Kv���j!�|����S�i��'�ğ;z�%��,x8Gr���}Pi����+��KN����Ozv�Lf4���b�}Biy�yZz.�g�0�?~�k��X<#��!�x��}blz˹�M���O�Y�l�I�����O~n�/"�8x��Ͳ��4�.?�q4������3�t'7y�zn�E:��ؽ�2���53���w�_�؃���by+Ne~�ށno�>'nv[�?�;�c�]ݬ���˫O�����\��&������dr5�3\���>��{�n��G$s/�;8��j%ú�U��#n�WyAd3�U����Ȟ_s�	�y�3'�;Z��cl�gւ\UJ�����gD����r[�S��yS�i��V�Ou7����U��M6j�F
���sU~���\lJNM�����V�.���n:��w�F��[�ކ��N������z�� Ay:$P�^U1�;:��WWX����j�ƅ��%,�|�]R��*\��ԟOZ��{���Y,Q�f~&Se�?�[>	�����$��/g������ǡzc���F�b�fOPu՘�m��Lu�JYar#��i��e=ګ5�/5���L}�M��#�]H�Y׌���%/<��1؃챹�U��$������oUS��1Ԟ��5�'\���xʬ�*c�z�[��aBw�l�Ոs��d��.�M��4��m�S�7�5!��ɷ�Y?6x�����	i�Ǵ�K��_�����=��%:�����{��~�dR�	�9�Bݳ�����y�ٝ��'A���6��q���������I�E�v,��VƤ}�b_Jȣ���|��"������ ֻA;E�ڕ.��7�H��#��h�.��?3ֳ{X(65��dq�P/�'o揃��u�o_V�M��i)"��.z��� �ɻ�|�n'v���Z�	����Q�O"Oɏ�wX�B�.��ET>NѤ���q�㊭����.SJϵ�% ����/� �
�[�~��t$��9b�����]Y	���א��
	����m��T�o�bـ�D�nyP`�
U����+"�}��r͔�bط��Ș��(���L��0����I��z+�o���p�����b��S�B��5�x����V�dǽ��?r<{��A�]4[����_S�O�"<׎�z��N���.>����-Z
�G�a|FuGn�agE�W�Tdn�t��bP��=�T���=��i:�|��ׄ�YB|�7���Cw�3q8��X��e�ln������6m&��t�U�=ǯekG�2�NI&��v|����p�`�峉���/0����䇾�iă/-ތ=<����6���;�|�%M��J�Y���n�b39FDD����w'~��Jk�c
�~G}mC�ń ��Q�k�Q�L���|�^�l'���e��b?q��ꯊ�D�$�$"�w���i{����K
ǡ�ï���zm���$��f����܃Q�a�.m���n��]�����u]����g;O:4�즈�8�pD{3E؝���fhU=�2q�z���7v�i=���q����6��������8k�Nı���n��Ϯ�6Ⳮ�t�s���v5����gD�����͉n�}$\�[�Y�n�����'l��v˵�6N�D��e�I��[p�d���CF�=�u��jO
��O���M��Z/�-Q��Q�#:.�/<B�4_t��z��g�j#�7��r>��m+�{O�W�
Vv^�Cg�dK^m}��j�Ƒ7Z���r�ڷ��[��{���IW)5a.�f
�f
bo���-��d����JqAa>�ہ3`1k�Ԧ�����M(�v��^�$�xx�:d�nP��@�j!_��|'�tֻ���}U�G���hL8�3n���+���4����W���<��9+(|�J��w}�!�1����==�u"�X��?iJ4X�����*b�
����<S-_�*����cL��n�j�Iވ�a���_k�}�n��8MR�Duuз��D����¦�U�r��ؗx�h7NWu�,����4��pN�C�����s*���qO?8 ���)8,_��B��W�K�!U�ĺ�tx¼��E��^y�-ta���OOuaw�>�T�b{�x�ԾN��߀!����Lp���^k�N	Qث] q���ŵ8y�Y�q��>翜�2�ul��v��
j�tT���C"���T�a��<wsG�w~��]waί)'F����in�T��Mvg|�^��9s�sk.�l�r��u���_�ǚ�f���t����q�_NE폼
~e�|��q�t����³�,Y�K�?W̙{�������5_V��R"}�|ѾAW������CW.���7y�/�R��c�1��t�u���)��?"MH��b���r���w8tk���Ĩ�'o�G�!�'5��r�\����s�����&1w���{|�h�靫��o[ �����G�W�b���݇o�}1k����4dJ��_�Z")�nN��,����������mG��]r�[������x}���f_;+O��q\��<�tH���eN'/�p]z��� �BbF\��=��	+֢���譾��{��~�6��V�x�7��)�zŌO����_M3������e�M�d;��~�{�C�-{p�z2B���!r�Wb������G��#zըl5a`�e�#���u�;�Q�Q�����HT\�([��B��|�˘X���%Q#_�R1k�p=ۭ�d��{Us^=��I�zTt�g6q��9���]'�@��+D��K%��O��p�c֔�eٱ�v�������2F��p��8󈱏��}�g�:�oY���Cv�r�~G���6�����X��7�Z?"������P=|�n��!���W��8!���K�%���Kۥ�d�^g�U�	���ǳ���N�*��hԟؼ��k�@�=�y�Q�r�����3�����X�U�ǣe�ffrr|ja���3��z�X�9G�����y�:�bO�z��������0�O�����g�����O����9�|���wć\~�#�f�nOZ�K�;�&�x���S��,�{�XV�c�����:w�4��Z�����������}��W�<3|ٔ��G�X��k٫ʽ�h��Q6���m&��{�
��;�fl6�V�����Wt]�2Y�/���F��\W�<�8�۽����7�G�Zv��^GUғ�]&�mwe
�=�}���"��ֲ�����u�%^i���
�����f������=�l�1?Ӗ7q]������7�=.����������)�(̼�c~���?fj9��&ԕ��?�Ifa/��>�G��ͳ���.t����Xxݧ�aY[7�|��z�|��,�-�<dҰ���������Vp,k����+|�l{��5
'�'V�0�L#Ƕ�"�*4s���׃�b��U�^��3u���:�hv�sQߕ���輮��d'��.�����>�r~�Á��Wr�-p�85d�s��k����=3����ݺ�����������,�o^R0�h�SΛS��Vλ*����ٿ�����:.3��RUa���Kt��]Z�Dt�֗��ܯ�}O!�hz���x��\�٬���&ߖ�2��՞GV�v��j�6ÙH���W��0q��{������n`E��ܢ9y͖�?�Gs�2y*z���{���"/ׄkss���!����>��&��Q����!s��'��I68=t`��p����n|	9�=u4{�r��-Wg��3~�l6�(i}k�m��gH+����*rF�c�V;ȕ��çœ����}��S���a���`����z�Sm�,��=<&����s\�w{��a��3S��aKf��>��c��~ߥ�f-vJ�:.��F�͖��9�X�<�M����������(�iq_�?�_uq����ͯ;��3��ھz}X�j�)B��xa�q�p��N����V��w�M���/|K����XR�<�7j�ݟ��[�no|ړlnt{�dg�6���{��dU�gT16'��9��<l���3*��3����1��!���J�qp��f���-���S}`a�&K���-a�>x>Y]:E��ݭ���dV5]�{�{���#t�K��*x�ݬ��s��^��I�DyX'5�f.kG��u;���=�L��2u� �+'�H��hT���yD��)�\I���[�􅍮��	'��L����lɗE�d���M��V/.h�Ϻ�8���A7�Q���=�>׫S*^f$�ȵ����N���>W0����ŏA���<�� �|��%�H��[f#P�U�� �}��f���<N�~3M{8-�l�q|a�}�'�k&y�cT����&��I�><眪A��i7��_���!p��7U��j�'��VF�TŨ7m�|�1����n
[�����d�bŅ�
��Ҁ%�?pȲ�䤠{mȅV�]ډ�[rXߛ��괕�J�;0���e�HǶ�ۊ�Y
佊T�ǖ�Iۮ�թ箮���⾓�ዮ��ψ%������:�M�_^����h9|r���O��q��-��N��ݗ�dAAqp�Ad�;-:65�ds�n�#����h��A^�|�O����p�ۜ��#�R�4�ǒ�i]�='/]N4�����p�����o����:3
���W�,�x��[�����/�Ϛy�1ywFAÕ^������ꊫE�<�ad����3����Ms���I޻��^���J'�?Z([sQ�"gN��$rA���p~�l ���{֠��IEGFu'7�"�H��ȉ+�z}�Q]t
z���fբ�W#[T��+�<|QOr|����Gz�6��_���7w�Ŧ=H�S�]�뙒\�G��ygT��F���UզN�dղA��{K_k_�#L�|�����P��fZ��k^[�����4��˄� ,��;�hl}C{�,��7�e�ŷE����9*�J���d3��=n�$#�`�>�/�Z�}����ʋ�$L�T�t�& �^��y��%�|\B��.r�nw���V?zB4}����9�xҴ�kmȸ�#�H�Ә��v��=��?/�8UTHI���2��d�����WT�I<L߶�����m?
���#�
�%壳{��?�����E��}��{$�X���s�>"��̊,�
����b�M,ɩ;���=A�2u�o�n��J�>�G֓�3en+�����R��9��sn=��Y7��i��<�X�兺��{��&>J���h�prY��]@���^�̗(�~eXz��b��	L[4U-�!6�w�A	7�>Q�nq��FR=>�$�ܸ8���/�Dz�	�����g���e�Y����|5��L������MZ^�#۔�����Yn���l�L��e���"����N�Z��P�����_���=w8k���7��j��u�C\�+�+��d5�xҡ�NA��}6%�S[ݔ'��(�q�������!�`��>K���jNL�~4�ϕ��Vǃ�v��@۵`_ߗ���f�L��9�ß��;'���7���ZvP2�ujPF�ws�F�g6Y�q��e���>����2��	�㝳�ԍj�lK�{J�߳��}�|�����L���v'�l��--6,��2����{n�f��w�ȧ�m�f����4D1���`���rńK��UD�L���D� 6�m�[!�~�ޘσ�+�w|�qE	�kҶ�3�m�g�l��ܙ�Km�:��ߴ���̎�a�m�d1u��"d]����P;�����B~�<�i��sS��7tt<<)��iGMd�<y���`��W���M�e��_Q�8Pq}W�6lnX��
rM��J*��ӏ;���d���ω.'_�3.��N����(��
�����n��ٙ?%�C�Fd�n����*!~�p!f[o��m�kL��l���m�����#W|!�_4KK������������'���h�r�LL����Z��|������]�i;!'&����W��]�ev��|�{sfQ�D'��lY��Ԝ�k��nu��sψ������2�V;�V�i5l�'�H������ͤ���������2�)-m��>!<�����ޒ�|r�2�HNz�"2ND���Y�p Y?euw��|R�H� ��A�����P��GyzH�8r;��2�XrLa_�a�q��^cz�-���]N��nso��*�Ӧ؉+ٝu���<�W2F�@����W��{�����o�j~l������`��q�m��	� ݧ�p��'<��`��3݂ҞzL}�̱?��������g�p����W�w��_��ُ��qn��D}����e"eVҾ�M�'V��h�v���g}֍��bQ�"�,�h4Q������D�˨�܉��]?�qH}��v[6qj��K���O�}�ߐE�k����z²���(f�	�e�*��-�l�����Z�fL/_��!E�GN�flR$]�1f#]�`v�E~��Ə+|�h�{��.�ъ�ךm�pW�2O&4f����s�3؊�-G�[E�����,�P���<���E�9^Q�����G�v�)�}vzw!�[K�cNN[LW���Tob�훷wz��nt�����^-&z8��9>M�=>�휺3�X�0{�c$ԭ����{����ǜvǎ���f���
$��lD�r��r���n��\�Ϟ�3U6*'c�&���֜M���S�7;�~}��8�%��Ց3��U�M�[rf�
7/Mo�Y�����uY5�j���a.�F���s�ٖ}w��wO�$�ˀ!̞d|���a��ճ�J��l]w���߬Ǭ���1sw���/>��(��r����;�7>������d�aͺ|"
�=�v�=g,g���Ǆ���Ur�s�rs[�:���yy'ye<c� �<��@$:.҈��b�8^���S?Hme;edf��
E��L1��J0lA���e/fs�rNp�r�p�s9�@��'��`�0F���􍬱�^HY��;�s���ϢdI�T)� 笠��c��7\�\�R�	�[^ ?������$P
V
NJ!�4�ja��p�h�h�H%*���׋s�_��$K%%g%e�H�厛�;~w/])�*�(-�N���m�]�������wʯ��x�z�n�u�11��H�%nw`.PS�d�f�~�-v�T�V�A��;�����-�j��^�,�K^)Ϛo��˟���o'`�
Ff	2��0B�.\'T˄D�E�D�Dy�r_|ձ�4B:U�Q�WzSZW6]�KvB�H�Z�@�"ϔ���7WtP�QL��=	OH!N#\���Ov2�(�ǅ�yͱ���~��u�y���	$� �[�DǍ�V(O4��8�R�i!+\$:!^�8Y6\1�@��6�|{7�g*t
�B�pVx*�	�%�U������G�W�L�!$\"z�b��Py��O�ww#�
�@��(h.l/����	����:�x"�(�,�r�}�3�GCl)�������a��T�*��1��3�;�I�L������
�Β�K�JwI��<d��w�����ț����C�1�D�a�����\����ercE}ES��B����X�ث��x����$�	;xF0F1�j�9n��.w ���;���W̫Ƿ��O>��_�o �%ԳB�K�>*�=�����v"�H*rm���č%�%lI�$Z�_r^r_Rױ�cG�q�c��S�׎_M��&��R�t�4X�"]!="�#-�j����2�����X|/WV k,*�O�)z 
��X	=Ċ����Y�I0$���f���EoD"��x�x��q!���7��$�B�WrLRR��1�1J�%]��{he���,Z�$�){(3�{��|�|�|�s�p������'�i�"X���"J�U�P���ބB,$V�̒OT�MF��h��׆���ʎb�g�c`��M9�8=8��T�Ӛq;p�s@�Y�=�-�Z�:�ؼ��p�b�*�~�E�u^>�	o����H�Z�
eBWa�p�p�p��'�BcQ+��}D�����@��DoEm�\��C��ģ��G���_�T`!�" �<K����?�4s��q��l�I� �2�����.ґ�ip�=���x�t\��M������ʾ��nrgy�<Y�[�V>R���8
�b1�X��C��O � Nڰ��Cى��������r8�9+��g������ø����D�PC�������{?�y��������]G�D ���7]���}�3�A�pa��]�¦п������փt���C�+�gQ]���R��x��8[|M�UBJ�JI�K�$�$�$��"���;~v,s���X��g�pi `d�t��������������c8��˲r�|�|�\%,�Q�RL��|DqYqO�H&���e'�D	ȍF��FH����	�v{{;�[žö�4����p�8Q �q�sn¸�Ӂۓ������p�r�p3���xV<;^O�0���M�)y[y�x�x,�=�F�y�=|�`�`,�*��W���� +8	w��r]XF�v��"��U�.�)�(�!�(�$� �.�]����cAZ<!>c���\b-� #�T�)���,y )�|�0��9u�8�q�iGo:yR����]:������\�Wi3Y����l�l�l"��e�e�d]�<��!r�>�)���
39�8��z܎�\Wn<w&w5�$7���)x^�i�� ����'�F�'���W�w�������gX0uA��������
���Q����8�1��c1���4)�ηJJOH�NJ�����!�8�fk��2�e�d_��y���	�͗˷ʏ���^n��SHC!�8E�b��p�O0n�)MFc�f�ۧ�r���\b��6�ۜ�(�?{{
{.h���{هٗ�/���`�qp�sNg"���k����\)ׇ;�;��$��ܷ �4�ȋ���c�k�-������������ ���>N�-x x)� h��+�=���W�OA�-2������ .KE���˥��@�� �.�懸.H;��~��6�XxZ�Б
�� �0�ፊǊf�
+��ɊY�L�F�LQ���7"�����8�����b��
5�4�t��y��c����#P4Ph2www�0`4�{�{F�o\^;^�Cx�yѼd�O��]«����mw"�e����W������o�����Ƃ��ƀo;����<p>A0C���-���Ԃ����x�p1��W��N���"�����M���c��Z�N]a<�{�$F�PrPr�S
�H�a0���h~?�?��<�~:��U�u�M�m�5���y�1����ĿTyp_ ���8j	��_�/	�T���`%��l���C�g�1ȭ$�h}�^0Z,Y!t�I�D�ig	�	�ˠ��ll��Y� �������\�]A��B��V�VP"(�>U.`M�L���%�Zm@���l!_(=�����]8T8L8R8Z,F��'�$LN�}y�0]�L�
��M�m S�f���^^�
�
�@�)}KcF��F�r!Cd*b��E,����0[I�E"��ҥLD�z�����9T4L4R4t�PQ�(ƚI0�O��-��h�J��m0����HK� /�]]���@n*� ﭨ��2��bS1Sl.f����b����b1�+�X&&A?�+(v�v$�I��Pq�Jq�I�D�t�,�)��A�)l�x�x�x���Q�L�$�K�5�����a� n�V\".��ˁ/�J� �$V #�HlA갗8��̗�%2�5z��1P�t#c<�;R2��PI�$Z��s�~��Ȩ��������>�}�����g�3�w�ᄖ�\GED����]Ѓ���#FƇE�D�1u��c����uwp�9nd`DX�Ȁ��Б�q�q��T2:���� PK    �p?��(�w  ,     lib/auto/Math/Cephes/Cephes.exp}Q�N�P��D��EC0�	)h\u�BiI)Ӥ�KhRҦ4n�?��`�W����>��0�9wz�d���Qy���+
�HP�i��
I�_���B=�aj�Ie��]
�EJ��ᙺ�4c��{�.��%�pI.�m�Ss��
%=gdj��Q���C�|25���)߄Pc���n���,D�`�dyhdՀ(А��R�P"������xiw��xS��PK    �{?`I�|   �   .   lib/auto/Statistics/Distributions/autosplit.ixU�=�0D����H�v��ܩХs�,����_X
����Tzp�p�7N�xj����({����ݩ����J	�3_�0�;�t���J;�<�v �\�v[�O��	�MӴ��U �#�b,w3,3|PK    �{?��4:�  �
     lib/prefork.pm�VmS�F�,����m�����&$�L �a��zC:�h\��w���b��zF���>���s�Dġ�$��8}p��e'l��f̷#�nk�_m;�8���G�1���H�<`ik�nO���Lz�g)�����V�&,`�Y�V��K3x\,;_��W��1t>\\~����_��χW����z�����~?<�ai[��18}w���ެ6\�9�LD�I�[���&r.20I�d�.���֦"�A��Z�@�
r1����Q����xZ`N�Lۋ(�
%$%D����b�s��jG�?�@G­Wqȥ)�9G;�S�9gO��ʶ��l,:��J��(�ǰ�W���xm�r����e�e[�`�q��Z�	��J"&!�܇\U�J�Y�ak�ꃘBg8��Ė�}^�cЕmSmE�ĸ/!@a3��}��"��z ���#"�ӃЏ�x%Y�aO�փ������vz�
��rH�a�
>�[���!�!
S�2
uU4�r�/�,&*����������o��	f�!��b�b���O+��_��-�^!ּG��O���ēG���:��GX�����U�O�`y�����s[��2���Ә�9e���C����a�$�4
�p8x5ҾF�b�5�#J��
Ӆ������OG  =��fy�V#���ݸ<�B��N�k�gk嫽v�)ś0�
��%m"�Qj!���'Y�� ������0�F+@-�p�,b�荨�셧N�WΟ��zn�"��\{ͽ�V�]�S��w�y,/ъ«0!@`1$"� ��
�c��8S�;��+^���v����Ԯ���V)��\��o�B�ycô^�ίTq͐S�my�C'�أ��D�q@k̙�:܀�5�km�T���:��Ǫz]+���;��yI�
:�NWg�tZvWt����|�ɘ�i�xh����EX��X/E��%qIH�IO1D�Z�����
}Б�Wf����ej��F\Du%�_��Yhǚ(��6�V��������&>_հm�qO� ��OHU��}ͽdm��~<C�.�E_'	�-��J�5a9�������P�L�5����c��.�r(ed6L�m�UN����y�
�sW�x�:jӻ�z�:�P����L����j�n1Go/�[���Տ���Q�g\t�1XW-tݜ�vF7q�ah�Z$T��I.�t<?D{�b��`��V���QC*����DL����'��D����Fua��P͌���:	�-'����}�q�R�q�����aE�^N�UI���S�.;�pZ%vā�e��"�����L�N�FE�\J6D�vE�a^z�Mw��x5��=���?�P���E���&�>�����J5jMbC3S�!6e\s9*.��$���AD�K]��y�[�qq�4�끫,�*�i�C�%G�u�_G� �:�D���i~�? �>8��G��x0
L ���N�I�����X]K,hZ�e�G1[<�}��hȦ����Ŏm�3-�������jn�^���*E�-eg�<>����su`��у5?>�n�}���~��+����ﾳ��w��7_��G�����X��'��@�	����)��$v����|�R�fa�Y]�
�Sg�^q�)����a]k�=���5w|샯���O������ۿ�{i�����_�����n�zi|l�;L�X�wl�e|ߤ�p�j�4=�r��
A��E^�f�ߊ�7X�F�N���}�C�\;4g7k� �������ǟ�������|�����?���>z��7o����������/�z��{�?��������7��|������W�}����������+������{a^�����;��֟�Є0��j�>j�c�@Et��^�Z_j��LA|)�EN|�!�� ErѓB�@,����n�io:�_D6���RHq��Z�?�W���d��LN���v��n
�r��/� �Mq��r��gw�nj���^��m��Ħ2⁑���b��7�˰��|��:a���<x���[�K�q����h8�`LQ��;�J��&/�va����Z�ׂ����?�V�-3c��B	�}UY7a�	 _[��4�ef�2 ??J�(�_�	�sK[�yǀ�P@�rEш���L���u�Z���"�P�!`�y*iY��aY���Vڃ�qh߂�+@�u���x�P��nM ,��Ad��&�d7¨n��2
]��@��s��_Ecʶ܊����-~���z�6�Y��4ah!���m��-�W�ɇo����*�o|�zS	�X·�R}[8�nr��A棓��74L��p��w^��U��*"���f�.�ё閷�Z�J�*���P]�1�G#�����]������z��V��jvo
�m¢҈$,_�/���W��Z����dY������ʟ&x���k*Z��%���SKO@� �/�59�j�*�
u.� %'�'v�*�	EX����hG]�����ᛓ�|r7n��j�4�`�����G]-��-2�9�q�q�bA+sS�A'��_ 	].�x�H�뮩a��ќv�=D�ň��j��.����K�|�T�Mo{RJ��B��*�0���m��I�)5�m�Q�-d�c]qרs�EJ|Qt��`Ƥ�i<2��Z,M�h5J�z��ҭL���p��|�V��X��<Z��9��f�̶)F@%z�H}�s���e�E�s�
�S�DC$�崤�r�A��8�*�����@&��KA�������E��<��L�~��{N�4�A�8B7B|�(�FU���@���XQꙂB�N[���D�Ś;Z1-B*��C��
u�
��l�)n#�A�U�?@�Z�Y�k�N��>���/o��`ti#j R�A3$`�bT���X�pݴ�:�.�8 ��27���.BϷOq�R� ��?��\��C�5�H�P��b
E����������ZT�9;��Z�u��BJZ�u׸2����و�+��8���S�)�J��76�����fm[��kmL��0;u�ZfZ�a�)"��I!MD[��E���p�����۵2;���@i��#�ٱ�~l��� ���s�sc�L+�oj^�w7aևV,t��;sze�<O�ÓBJ��\�=j���Ǿ��B2KtM.ѵR�Dl���o9nX�<�o��V}U*�Ӝ���6���y�-qa����yC>�����_��O�$2���wt�r\P�!�e�%�4�"@�s�k¨Z�*!��G�˒�Ô�r��D��I3:���}ET%�ߨT*�G������r��ϔ��ͬ����\	��57�4M޺�����ӷ��?~~�[�ڙ6.����%7�t�=`�~=��&�x���H{���'�,R�UD�Ü��ym����N�L� �B�O��	�2��������"~�sE�$B�Bh�Q,!�a4a�2�V�����%�eȜR�8�.5�ո�/J!1$f�B)�J�Z�rA b�b@a*��C��)�P)���C�#V�J��»ǕMn�a�}JAB_쒆H���깬
�����}7X�\G q�I�{�d��IvIp�
r���m:��qB�� H ��"��5��L���Je�oS6֕� �<�YH��N�z`��P�m0y��)�k�1s:��{[RY|�V�H{�&ς�X��@�#�J�P�%��z��7�] ��uC��6� &Ǐ�a��f؇K�sbg9_v^4>�'㼊�ýtlL-X��
2?>vƁ��s'K�R��t��]�\b'}�����`��6�r�,��-�����:-߷]�kO=�)fjshB���а&;o��ܴZ�*8��Kˬ��O,�'��Yu��c3S����W�cCW�CV�#b>-D�����Fqy�qLZ�XK���|ғ,��!O'k�R8K��)0sK$�N���S�
���F"[���bc�U�����x�)?�L&T!�͵*-�����(":c,��(�SCjT��8�p=x�J�:���X��x�����B�P-�L1��&pL��׮x{�mӾ^�⊼�N��l�`VQq-N�t����� � �r�͕�:�hr'y_5N`�Y��l�A[�nz�7��]-��V ,��A�7��I�ǖ[9}z_\��w�~E�/��Bu���=0�s���1�w
Ov,���-���U�Fh�
� �jo\��^��kH�$]�5�N�eb��A�
i��Y��ѱ�[�o�|-{��ml�����,��Bn�ON]65�m��}Zl�X�ű{�iu
��'n&CEv� L;v�w�s�L���ڧo��拯�x��˯��)������>��<IV��C�E�N"[�_����� v�0*}O(s� ���b�\�F"�ړM�i��=-�_�
(gP�tI>�I=�M<!%�ĻK(M�Pؤ��HF����4;���)v(P���t����Z\K$�DM�^l��쥳
��U�!��k��'xJ��:C����W��U�~��n�2};H���@raD�u-�K�+�R�@5
�S�4���f�E������"	���!s=�n�������b�p%�������8���a?y?�!�����48�9-��k���314�=%s�owɮ|��ۿ��KvF�I
{(��/2���G}`_��Zy3��%��S\]Jssz�6��K��`��޿�B�]�
��C��)�D�����%w��΍LކΠ:�tr�{Wp��Y��G)\�Y��`���_���Wo�F���t�KL��2�����Tߍܠ �r�;��5d,A�<�������?�-���<q�
4ܴBf��6��E�p2�D�R,��B��X�F�r3�D0`�@I�%�E>�i7���������
>�)��� ��^s�������M�盛�ݲY�?BKJ`K1��#�-�-���P�e������H&eǜjǨ��}�O_�FR��q#Y5�}`�ܗm3ږ�Q���(�cT�f�q��à�(���G�b0"xP��cC�Q�Ź�0F�GK5 ��y�x�@L�P9����20o������Sl�Qe
d)��B�@%��p&1�)$.�ĸ�b�Y�><� �>eǥe�i`�n:F#�vH��nt��)~�1]R[��,�s|N`�R�zr�(�]@	4mR
�5?,tl�n6:S�T�ǯ�3��0^:gj�"z�U*�1��~�}kbi�/t7x
���qR�Y7�AE�x�O	1v)�0XLt�CV����H�)�Y��o�<�5)����ΣH�M&,y����0܂)F��F
_�V֟+���b�ڳ�95x�rʔ��H�"�
�V4DB����#8�e�m�(��e�[����eg�%�~�X�h16f$�
��Tq:�8� ��Q|�b�;`�Q-�EJ���L 0�7�z�K���N�G�2��������T������e�
2�E24�r�H9jSQ��x�A��C�hڶ�������A%ְ�*��IX�a����i�m���ȸw?=ϥ
8�E��$C���c���@'��\]O2E���5�fgjfФ��D�L��blə��	n���g���S9�����Z���9��
E������'K��+�J�T�T���Gu��b���\��4����r�$b:1:��6�N:���^gq�7�o>$c��6�Wr��^W���=�P䚄"�$/n�G�.I]9)}�O��C%�#\`�'�ON�X�	��./���aP�l�}d�h�M��i5B��쭚�c*�6�"�h۴��5Iy�&���<;��r5�Q��oB5KG�ld�U���]r��8���Itk�()�Hr�J�Ew�%FR$e��g0��0�t��;�	��-{��vL���L�����ij��fic#��G�tՙ���q��1��-�Fj��U�:agg�A�yB�It�Bg%��Hܬ�@I^{B��� Ç�z$�1LGE+@�v�����{bh��4�oifF�;c:�����I�j���Hh��:W�c	��%J����
�"պ�<�s�T��0=(�g]\�x@|E��/�"��[��ˉ�0�&~2L羂�8Z<���:���Z�8��GS���3ˊ�2�����+�fy��/d�������M��߱�
�G��v=���7��!��i�2�=#}2�����I\�O��]��m�*/Fv�@�'�3\K(�Re�a��t$j�i�����T��a�ω�ŅU�
.�����N��A3��
���~�ֶ�J��w�涖�""1Q�?��$���m�TQ�)T�� 5cTIZ��+gc��A��dא�@��ο�/�����V�=��L�(�|G~t�!�'��{�Uo+ƻ��X�n2(�:�Ԍ��:�P|��$��ur˘'�J�]�`\����)o�A��k9)�ٰUX���b��m�hV�Ƴ%.K�ϸ��gpVƳ%e�RH�����:97pq�@�)�4Q�>�~xӾ�mBd,	
  �F  )           ����  lib/Excel/Writer/XLSX/Package/Packager.pmPK    �{?6�BT!  �  .           ����  lib/Excel/Writer/XLSX/Package/Relationships.pmPK    �{?)���    .           ��5�  lib/Excel/Writer/XLSX/Package/SharedStrings.pmPK    �{?%QL�  �R  '           ���  lib/Excel/Writer/XLSX/Package/Styles.pmPK    �{?�<N�	  &  &           ��J�  lib/Excel/Writer/XLSX/Package/Theme.pmPK    �{?��  �	  *           ����  lib/Excel/Writer/XLSX/Package/XMLwriter.pmPK    �{?���wn  �  0           ����  lib/Excel/Writer/XLSX/Package/XMLwriterSimple.pmPK    �{?����%
  �&              ��V lib/Excel/Writer/XLSX/Utility.pmPK    �{?�a~�I/  ��  !           ��� lib/Excel/Writer/XLSX/Workbook.pmPK    �{?���\  �k "           ��A; lib/Excel/Writer/XLSX/Worksheet.pmPK    �{?l��%c  �*             ���� lib/Math/Cephes.pmPK    �{?!D  _             ��/� lib/Math/Cephes/Matrix.pmPK    �{?�a�x�  �f             ���� lib/Number/Format.pmPK    �{?ү�6h"  �w             ��t� lib/PAR/Dist.pmPK    �{?�wR|�*  �             ��	 lib/Statistics/ANOVA.pmPK    �{?�~z�  �             ���5 lib/Statistics/Basic.pmPK    �{?pd�    &           ���: lib/Statistics/Basic/ComputedVector.pmPK    �{?�E�  �  #           ��
  "           ���A lib/Statistics/Basic/Covariance.pmPK    �{?�wn��  �  &           ��IE lib/Statistics/Basic/LeastSquareFit.pmPK    �{?�4,`�  =             ��SI lib/Statistics/Basic/Mean.pmPK    �{?����&  �             ���K lib/Statistics/Basic/Median.pmPK    �{?�)=AJ  i             ���M lib/Statistics/Basic/Mode.pmPK    �{?�(
             ��� lib/prefork.pmPK    �{?��1  �             ���! script/main.plPK    �{?���{7-  ��             ��1# script/miRNA_1c_ana_v0.3.plPK    < < 	  �P   d8c0920588809712e6eb3510e66b121426945f1b CACHE ,
PAR.pm