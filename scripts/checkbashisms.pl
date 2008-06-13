#! /usr/bin/perl -w

# This script is essentially copied from /usr/share/lintian/checks/scripts,
# which is:
#   Copyright (C) 1998 Richard Braakman
#   Copyright (C) 2002 Josip Rodin
# This version is
#   Copyright (C) 2003 Julian Gilbey
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, you can find it on the World Wide
# Web at http://www.gnu.org/copyleft/gpl.html, or write to the Free
# Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
# MA 02111-1307, USA.

use strict;
use Getopt::Long;

sub init_hashes;

(my $progname = $0) =~ s|.*/||;

my $usage = <<"EOF";
Usage: $progname [-n] [-f] [-x] script ...
   or: $progname --help
   or: $progname --version
This script performs basic checks for the presence of bashisms
in /bin/sh scripts.
EOF

my $version = <<"EOF";
This is $progname, from the Debian devscripts package, version ###VERSION###
This code is copyright 2003 by Julian Gilbey <jdg\@debian.org>,
based on original code which is copyright 1998 by Richard Braakman
and copyright 2002 by Josip Rodin.
This program comes with ABSOLUTELY NO WARRANTY.
You are free to redistribute this code under the terms of the
GNU General Public License, version 2, or (at your option) any later version.
EOF

my ($opt_echo, $opt_force, $opt_extra);
my ($opt_help, $opt_version);

##
## handle command-line options
##
$opt_help = 1 if int(@ARGV) == 0;

GetOptions("help|h" => \$opt_help,
	   "version|v" => \$opt_version,
	   "newline|n" => \$opt_echo,
	   "force|f" => \$opt_force,
	   "extra|x" => \$opt_extra,
           )
    or die "Usage: $progname [options] filelist\nRun $progname --help for more details\n";

if ($opt_help) { print $usage; exit 0; }
if ($opt_version) { print $version; exit 0; }

my $status = 0;
my $makefile = 0;
my (%bashisms, %string_bashisms, %singlequote_bashisms);

init_hashes;

foreach my $filename (@ARGV) {
    my $check_lines_count = -1;

    if (!$opt_force) {
	$check_lines_count = script_is_evil_and_wrong($filename);
    }

    if ($check_lines_count == 0 or $check_lines_count == 1) {
	warn "script $filename does not appear to be a /bin/sh script; skipping\n";
	next;
    }

    if ($check_lines_count != -1) {
	warn "script $filename appears to be a shell wrapper; only checking the first "
	     . "$check_lines_count lines\n";
    }

    unless (open C, "$filename") {
	warn "cannot open script $filename for reading: $!\n";
	$status |= 2;
	next;
    }

    my $cat_string = "";
    my $quote_string = "";
    my $last_continued = 0;
    my $continued = 0;
    my $found_rules = 0;

    while (<C>) {
	next unless ($check_lines_count == -1 or $. <= $check_lines_count);

	if ($. == 1) { # This should be an interpreter line
	    if (m,^\#!\s*(\S+),) {
		my $interpreter = $1;

		if ($interpreter =~ m,/make$,) {
		    init_hashes if !$makefile++;
		    $makefile = 1;
		} else {
		    init_hashes if $makefile--;
		    $makefile = 0;
		}
		next if $opt_force;

		if ($interpreter =~ m,/bash$,) {
		    warn "script $filename is already a bash script; skipping\n";
		    $status |= 2;
		    last;  # end this file
		}
		elsif ($interpreter !~ m,/(sh|posh)$,) {
### ksh/zsh?
		    warn "script $filename does not appear to be a /bin/sh script; skipping\n";
		    $status |= 2;
		    last;
		}
	    } else {
		warn "script $filename does not appear to have a \#! interpreter line;\nyou may get strange results\n";
	    }
	}

	chomp;
	my $orig_line = $_;

	if ($makefile) {
	    $last_continued = $continued;
	    if (/[^\\]\\$/) {
		$continued = 1;
	    } else {
		$continued = 0;
	    }

	    # Don't match lines that look like a rule if we're in a
	    # continuation line before the start of the rules
	    if (/^[\w%-]+:+\s.*?;?(.*)$/ and !($last_continued and !$found_rules)) {
		$found_rules = 1;
		$_ = $1 if $1;
	    } 

	    last if m%^(export )?SHELL\s*:?=\s*(/bin/)?bash\s*%;

	    s/^\t//;
	    s/(\$){2}/$1/;
	}

	# We want to remove end-of-line comments, so need to skip
	# comments in the "quoted" part of a line that starts
	# in a quoted block or that appear inside balanced pairs
	# of single or double quotes
	s/^(?:.*?[^\\])?$quote_string(.*)$/$1/ if $quote_string ne "";

	next if m,^\s*\#,;  # skip comment lines

	s/(^|[^\\](?:\\\\)*)\'(?:\\.|[^\\\'])+\'/$1''/g;
	s/(^|[^\\](?:\\\\)*)\"(?:\\.|[^\\\"])+\"/$1""/g;

	# If the remaining string contains what looks like a comment,
	# eat it. In either case, swap the unmodified script line
	# back in for processing.
	if (m/(?<!\\)(\#.*$)/) {
	    $_ = $orig_line;
	    $_ =~ s/\Q$1\E//;  # eat comments
	} else {
	    $_ = $orig_line;
	}

	if ($cat_string ne "" and m/^\Q$cat_string\E$/) {
	    $cat_string = "";
	    next;
	}
	my $within_another_shell = 0;
	if (m,(^|\s+)((/usr)?/bin/)?((b|d)?a|k|z|t?c)sh\s+-c\s*.+,) {
	    $within_another_shell = 1;
	}
	# if cat_string is set, we are in a HERE document and need not
	# check for things
	if ($cat_string eq "" and !$within_another_shell) {
	    my $found = 0;
	    my $match = '';
	    my $explanation = '';
	    my $line = $_;

	    # Remove "" / '' as they clearly aren't quoted strings
	    # and not considering them makes the matching easier
	    $line =~ s/(^|[^\\])(\'\')/$1/g;
	    $line =~ s/(^|[^\\])(\"\")/$1/g;

	    if ($quote_string ne "") {
		my $otherquote = ($quote_string eq "\"" ? "\'" : "\"");
		# Inside a quoted block
		if ($line =~ /(?:^|^.*[^\\$otherquote])$quote_string(.*)$/) {
		    my $rest = $1;
		    my $templine = $line;

		    # Remove quoted strings delimited with $otherquote
		    $templine =~ s/(^|[^\\])$otherquote[^$quote_string]*?[^\\]$otherquote/$1/g;
		    # Remove quotes that are themselves quoted
		    # "a'b"
		    $templine =~ s/(^|[^\\])$otherquote.*?$quote_string.*?[^\\]$otherquote/$1/g;
		    # "\""
		    $templine =~ s/(^|[^\\])$quote_string\\$quote_string$quote_string/$1/g;

		    # After all that, were there still any quotes left?
		    my $count = () = $templine =~ /(^|[^\\])$quote_string/g;
		    next if $count == 0;

		    $count = () = $rest =~ /(^|[^\\])$quote_string/g;
		    if ($count % 2 == 0) {
			# Quoted block ends on this line
			# Ignore everything before the closing quote
			$line = $rest || '';
			$quote_string = "";
		    } else {
			next;
		    }
		} else {
		    # Still inside the quoted block, skip this line
		    next;
		}
	    }

	    # Check even if we removed the end of a quoted block
	    # in the previous check, as a single line can end one
	    # block and begin another
	    if ($quote_string eq "") {
		# Possible start of a quoted block
		for my $quote ("\"", "\'") {
		    my $templine = $line;
		    my $otherquote = ($quote eq "\"" ? "\'" : "\"");

		    # Remove balanced quotes and their content
		    $templine =~ s/(^|[^\\\"](?:\\\\)*)\'(?:\\.|[^\\\'])+\'/$1/g;
		    $templine =~ s/(^|[^\\\'](?:\\\\)*)\"(?:\\.|[^\\\"])+\"/$1/g;

		    # Don't flag quotes that are themselves quoted
		    # "a'b"
		    $templine =~ s/$otherquote.*?$quote.*?$otherquote//g;
		    # "\""
		    $templine =~ s/(^|[^\\])$quote_string\\$quote_string$quote_string/$1/g;
		    my $count = () = $templine =~ /(^|[^\\])$quote/g;

		    # If there's an odd number of non-escaped
		    # quotes in the line it's almost certainly the
		    # start of a quoted block.
		    if ($count % 2 == 1) {
			$quote_string = $quote;
			$line =~ s/^(.*)$quote.*$/$1/;
			last;
		    }
		}
	    }

	    # since this test is ugly, I have to do it by itself
	    # detect source (.) trying to pass args to the command it runs
	    if (not $found and m/^\s*(\.\s+[^\s;\`]+\s+([^\s;]+))/) {
		if ($2 =~ /^(\&|\||\d?>|<)/) {
		    # everything is ok
		    ;
		} else {
		    $found = 1;
		    $match = $1;
		    $explanation = "sourced script with arguments";
		    output_explanation($filename, $orig_line, $explanation);
		}
	    }

	    # Remove "quoted quotes". They're likely to be inside
	    # another pair of quotes; we're not interested in
	    # them for their own sake and removing them makes finding
	    # the limits of the outer pair far easier.
	    $line =~ s/(^|[^\\\'\"])\"\'\"/$1/g;
	    $line =~ s/(^|[^\\\'\"])\'\"\'/$1/g;

	    while (my ($re,$expl) = each %singlequote_bashisms) {
		if ($line =~ m/($re)/) {
		    $found = 1;
		    $match = $1;
		    $explanation = $expl;
		    output_explanation($filename, $orig_line, $explanation);
		}
	    }

	    # $cat_line contains the version of the line we'll check
	    # for heredoc delimeters later. Initially, remove any
	    # spaces between << and the delimeter to make the following
	    # updates to $cat_line easier.
	    my $cat_line = $line;
	    $cat_line =~ s/(<\<-?)\s+/$1/g;

	    # Ignore anything inside single quotes; it could be an
	    # argument to grep or the like.
	    $line =~ s/(^|[^\\\"](?:\\\\)*)\'(?:\\.|[^\\\'])+\'/$1''/g;

	    # As above, with the exception that we don't remove the string
	    # if the quote is immediately preceeded by a < or a -, so we
	    # can match "foo <<-?'xyz'" as a heredoc later
	    # The check is a little more greedy than we'd like, but the
	    # heredoc test itself will weed out any false positives
	    $cat_line =~ s/(^|[^<\\\"-](?:\\\\)*)\'(?:\\.|[^\\\'])+\'/$1''/g;

	    while (my ($re,$expl) = each %string_bashisms) {
		if ($line =~ m/($re)/) {
		    $found = 1;
		    $match = $1;
		    $explanation = $expl;
		    output_explanation($filename, $orig_line, $explanation);
		}
	    }

	    # We've checked for all the things we still want to notice in
	    # double-quoted strings, so now remove those strings as well.
	    $line =~ s/(^|[^\\\'](?:\\\\)*)\"(?:\\.|[^\\\"])+\"/$1""/g;
	    $cat_line =~ s/(^|[^<\\'\\-](?:\\\\)*)\"(?:\\.|[^\\\"])+\"/$1""/g;
	    while (my ($re,$expl) = each %bashisms) {
	        if ($line =~ m/($re)/) {
		    $found = 1;
		    $match = $1;
		    $explanation = $expl;
		    output_explanation($filename, $orig_line, $explanation);
		}
	    }

	    # Only look for the beginning of a heredoc here, after we've
	    # stripped out quoted material, to avoid false positives.
	    if ($cat_line =~ m/(?:^|[^<])\<\<\-?s*(?:[\\]?(\w+)|[\'\"](.*?)[\'\"])/) {
		$cat_string = $1;
		$cat_string = $2 if not defined $cat_string;
            }
	}
    }

    close C;
}

exit $status;

sub output_explanation {
    my ($filename, $line, $explanation) = @_;

    warn "possible bashism in $filename line $. ($explanation):\n$line\n";
    $status |= 1;
}

# Returns non-zero if the given file is not actually a shell script,
# just looks like one.
sub script_is_evil_and_wrong {
    my ($filename) = @_;
    my $ret = -1;
    # lintian's version of this function aborts if the file
    # can't be opened, but we simply return as the next
    # test in the calling code handles reporting the error
    # itself
    open (IN, '<', $filename) or return $ret;
    my $i = 0;
    my $var = "0";
    local $_;
    while (<IN>) {
        chomp;
        next if /^#/o;
        next if /^$/o;
        last if (++$i > 55);
        if (/(^\s*|\beval\s*[\'\"]|(;|&&)\s*)exec\s*.+\s*.?\$$var.?\s*(--\s*)?.?(\${1:?\+.?)?(\$(\@|\*))?/) {
            $ret = $. - 1;
            last;
        } elsif (/^\s*(\w+)=\$0;/) {
	    $var = $1;
	}
    }
    close IN;
    return $ret;
}

sub init_hashes {
    my $LEADIN = '(?:(^|[`&;(|{])\s*|(if|do|while)\s+)';
    %bashisms = (
	'(?:^|\s+)function \w+\(\s*\)' =>   q<'function' is useless>,
	$LEADIN . 'select\s+\w+' =>     q<'select' is not POSIX>,
	$LEADIN . 'source\s+(?:\.\/|\/|\$)[^\s]+' =>
	                               q<should be '.', not 'source'>,
	'(test|-o|-a)\s*[^\s]+\s+==\s' =>
	                               q<should be 'b = a'>,
	'\[\s+[^\]]+\s+==\s' =>        q<should be 'b = a'>,
	'\s\|\&' =>                    q<pipelining is not POSIX>,
	'[^\\\]\{([^\s\\\}]+?,)+[^\\\}\s]+\}' =>
	                               q<brace expansion>,
	'(?:^|\s+)\w+\[\d+\]=' =>      q<bash arrays, H[0]>,
	$LEADIN . '(read\s*(-[^r])?(?:;|$))' => q<should be read [-r] variable>,
	$LEADIN . 'echo\s+(-n\s+)?-n?en?\s' =>      q<echo -e>,
	$LEADIN . 'exec\s+-[acl]' =>    q<exec -c/-l/-a name>,
	$LEADIN . 'let\s' =>            q<let ...>,
	'(?<![\$\(])\(\(.*\)\)' =>     q<'((' should be '$(('>,
	'\$\[[^][]+\]' =>	       q<'$[' should be '$(('>,
	'(?:^|\s+)(\[|test)\s+-a' =>            q<test with unary -a (should be -e)>,
	'\&>' =>	               q<should be \>word 2\>&1>,
	'(<\&|>\&)\s*((-|\d+)[^\s;|)`&\\\\]|[^-\d\s])' =>
				       q<should be \>word 2\>&1>,
	$LEADIN . 'kill\s+-[^sl]\w*' => q<kill -[0-9] or -[A-Z]>,
	$LEADIN . 'trap\s+["\']?.*["\']?\s+.*[1-9]' => q<trap with signal numbers>,
	'\[\[(?!:)' => q<alternative test command ([[ foo ]] should be [ foo ])>,
	'/dev/(tcp|udp)'	    => q</dev/(tcp|udp)>,
	$LEADIN . 'suspend\s' =>        q<suspend>,
	$LEADIN . 'caller\s' =>         q<caller>,
	$LEADIN . 'complete\s' =>       q<complete>,
	$LEADIN . 'compgen\s' =>        q<compgen>,
	$LEADIN . 'declare\s' =>        q<declare>,
	$LEADIN . 'typeset\s' =>        q<typeset>,
	$LEADIN . 'disown\s' =>         q<disown>,
	$LEADIN . 'builtin\s' =>        q<builtin>,
	$LEADIN . 'set\s+-[BHT]+' =>    q<set -[BHT]>,
	$LEADIN . 'alias\s+-p' =>       q<alias -p>,
	$LEADIN . 'unalias\s+-a' =>     q<unalias -a>,
	$LEADIN . 'local\s+-[a-zA-Z]+' => q<local -opt>,
	$LEADIN . 'local\s+\w+=' =>     q<local foo=bar>,
	'(?:^|\s+)\s*\(?\w*[^\(\w\s]+\S*?\s*[^\"]\(\)' => q<function names should only contain [a-z0-9_]>,
	$LEADIN . '(push|pod)d\b' =>    q<(push|pod)d>,
	$LEADIN . 'export\s+-[^p]' =>  q<export only takes -p as an option>,
	$LEADIN . 'ulimit\b' =>         q<ulimit>,
	$LEADIN . 'shopt\b' =>          q<shopt>,
	$LEADIN . 'type\s' =>          q<type>,
	$LEADIN . 'time\s' =>          q<time>,
	$LEADIN . 'dirs\b' =>          q<dirs>,
	'(?:^|\s+)[<>]\(.*?\)'	    => q<\<() process substituion>,
	'(?:^|\s+)readonly\s+-[af]' => q<readonly -[af]>,
	$LEADIN . '(sh|\$\{?SHELL\}?) -[rD]' => q<sh -[rD]>,
	$LEADIN . '(sh|\$\{?SHELL\}?) --\w+' =>  q<sh --long-option>,
	$LEADIN . '(sh|\$\{?SHELL\}?) [-+]O' =>  q<sh [-+]O>,
    );

    %string_bashisms = (
	'\$\[\w+\]' =>                 q<arithmetic not allowed>,
	'\$\{\w+\:\d+(?::\d+)?\}' =>   q<${foo:3[:1]}>,
	'\$\{!\w+[\@*]\}' =>           q<${!prefix[*|@]>,
	'\$\{!\w+\}' =>                q<${!name}>,
	'\$\{\w+(/.+?){1,2}\}' =>      q<${parm/?/pat[/str]}>,
	'\$\{\#?\w+\[[0-9\*\@]+\]\}' => q<bash arrays, ${name[0|*|@]}>,
	'\$\{?RANDOM\}?\b' =>          q<$RANDOM>,
	'\$\{?(OS|MACH)TYPE\}?\b'   => q<$(OS|MACH)TYPE>,
	'\$\{?HOST(TYPE|NAME)\}?\b' => q<$HOST(TYPE|NAME)>,
	'\$\{?DIRSTACK\}?\b'        => q<$DIRSTACK>,
	'\$\{?EUID\}?\b'	    => q<$EUID should be "id -u">,
	'\$\{?UID\}?\b'	            => q<$UID should be "id -ru">,
	'\$\{?SECONDS\}?\b'	    => q<$SECONDS>,
	'\$\{?BASH_[A-Z]+\}?\b'     => q<$BASH_SOMETHING>,
	'\$\{?SHELLOPTS\}?\b'       => q<$SHELLOPTS>,
	'\$\{?PIPESTATUS\}?\b'      => q<$PIPESTATUS>,
	'\$\{?SHLVL\}?\b'           => q<$SHLVL>,
	'<<<'                       => q<\<\<\< here string>,
	$LEADIN . 'echo\s+(?:-[^e]+\s+)?([\"])[^\"]*(\\\[abcEfnrtv\\\0])+.*?[\"]' => q<unsafe echo with backslash>,
	#'(?<![\$\\\])\$\"[^\"]+\"'   => q<$"foo" should be eval_gettext "foo">,
    );

    %singlequote_bashisms = (
	$LEADIN . 'echo\s+(?:-[^e]+\s+)?([\'])[^\']*(\\\[abcEfnrtv\\\0])+.*?[\']' => q<unsafe echo with backslash>,
	#'(?<![\$\\\])\$\'[^\']+\''              => q<$'...' should be "$(printf '...')">,
    );

    if ($opt_echo) {
	$bashisms{'echo\s+-[n]'} = q<echo -n>;
    }

    if ($makefile) {
	$string_bashisms{'(\$\(|\`)\s*\<\s*([^\s\)]{2,}|[^DF])\s*(\)|\`)'} =
	    q<'$(\< foo)' should be '$(cat foo)'>;
    } else {
	$bashisms{'(?:^|\s+)\w+\+='} = q<should be VAR="${VAR}foo">;
	$string_bashisms{'(\$\(|\`)\s*\<\s*\S+\s*(\)|\`)'} = q<'$(\< foo)' should be '$(cat foo)'>;
    }
	    
    if ($opt_extra) {
	$string_bashisms{'\$\{?BASH\}?\b'} = q<$BASH>;
	$string_bashisms{'(?:^|\s+)RANDOM='} = q<RANDOM=>;
	$string_bashisms{'(?:^|\s+)(OS|MACH)TYPE='} = q<(OS|MACH)TYPE=>;
	$string_bashisms{'(?:^|\s+)HOST(TYPE|NAME)='} = q<HOST(TYPE|NAME)=>;
	$string_bashisms{'(?:^|\s+)DIRSTACK='} = q<DIRSTACK=>;
	$string_bashisms{'(?:^|\s+)EUID='} = q<EUID=>;
	$string_bashisms{'(?:^|\s+)BASH(_[A-Z]+)?='} = q<BASH(_SOMETHING)=>;
	$string_bashisms{'(?:^|\s+)SHELLOPTS='} = q<SHELLOPTS=>;
	$string_bashisms{'\$\{?POSIXLY_CORRECT\}?\b'} = q<$POSIXLY_CORRECT>;
    }
}
