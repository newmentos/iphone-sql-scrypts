#!/usr/bin/perl -w
# https://www.jwz.org/hacks/sms-backup-iphone.pl
# Copyright © 2006-2018 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
# Parses the database files in the iPhone backup files and saves the
# output in multiple files: one file per phone number messages have
# been sent to or received from, per month.
# E.g., ~/Documents/SMS Backup/YYYY-MM.NNNNNNNNNN.txt
#
# It only changes files when needed, and will never delete a message
# from one of the files (so if your phone's messages database has shrunk,
# your old archived messages won't be lost.)
#
# Attachments are saved in
# ~/Documents/SMS Backup/Attachments/YYYY/MM-DD-HH:MM:SS-NNNNNNNNNN-NAME.jpg
#
# For this to work, your iTunes/Phone/Summary/Backups settings must be:
# Back to to this computer: yes; Encrypt backup: no.
#
# If you get the error "file is encrypted or is not a database", and you
# have double-checked that "Encrypt backup" is turned off, it probably means
# that you have the wrong version of the SQLite library.  Great error message,
# right?  Try re-installing the "DBI" and "DBD::SQLite" Perl modules (cpan -f).


# Created: 21-Jun-2006 for PalmOS; rewritten for iPhone on 6-Mar-2010.
# Saving of attachments added 31-Jan-2016.


# For debugging / exploring:
#
#   sqlite3 'Application Support/MobileSync/Backup/..../../....'
#   .tables
#   .schema attachment



require 5;
use diagnostics;
use strict;
use POSIX;
use DBI;
use Date::Parse;
use Data::Dumper;
use Digest::SHA1 (qw{sha1_hex});

my $progname = $0; $progname =~ s@.*/@@g;
my ($version) = ('$Revision: 1.30 $' =~ m/\s(\d[.\d]+)\s/s);

my $verbose = 0;
my $debug_p = 0;

my $iphone_backup_dir = ($ENV{HOME} . 
                         "/Library/Application Support/MobileSync/Backup/");
my $addressbook_dir = ($ENV{HOME} .
                       "/Library/Application Support/AddressBook/");

# Files from iOS are stored in the local backup under the file name's hash:
my $sms_db_name = sha1_hex("HomeDomain-Library/SMS/sms.db");

# For future reference, other hashed databases names include:
#
#   HomeDomain-Library/CallHistory/call_history.db
#   HomeDomain-Library/AddressBook/AddressBook.sqlitedb
#   HomeDomain-Library/AddressBook/AddressBookImages.sqlitedb
#   HomeDomain-Library/Notes/notes.db
#   HomeDomain-Library/Voicemail/voicemail.db
#   HomeDomain-Library/Calendar/Calendar.sqlitedb


$ENV{PATH} = "$ENV{HOME}/bin:$ENV{PATH}";   # for cron, bleh.


my %phone_number_map;

# Loads the address-book DB and populates the %phone_number_map with
# a map of phone numbers to real names.
#
# It would probably make more sense to read the number->name map out
# of the iPhone's copy of the address-book DB rather than the host Mac's
# address book, but I had a hard time figuring out how to do that, so
# fuck it.  Close enough.
#
sub load_addressbook($) {
  my ($file) = @_;
  my %attr;

  print STDERR "opening address book DB\n  $file...\n"
    if ($verbose > 2);

  my $dbh = DBI->connect("dbi:SQLite:dbname=" . $file, '', '',
                         \%attr);

  my $sth = $dbh->prepare ("SELECT " .
                           " pn.zfullnumber, " .
                           " pn.zlabel, " .
                           " r.zfirstname, " .
                           " r.zlastname, " .
                           " r.zorganization " .
                           "FROM ZABCDPHONENUMBER pn ".
                           "JOIN ZABCDRECORD r " .
                           "ON pn.zowner = r.z_pk " .
                           "ORDER BY r.zfirstname, r.zlastname");
  $sth->execute();

  my $count = 0;
  while (my $h = $sth->fetchrow_hashref()) {
    my $fn  = $h->{ZFIRSTNAME};
    my $ln  = $h->{ZLASTNAME};
    my $org = $h->{ZORGANIZATION};
    my $name = ($fn && $ln ? "$fn $ln" : $fn || $ln ? ($fn || $ln) :
                $org ? $org : '???');
    my $phone = reformat_phone_number ($h->{ZFULLNUMBER});

    print STDERR "$progname: addr: $phone\t$name\n" if ($verbose > 4);
    $phone_number_map{$phone} = $name;
    $count++;
  }
  return $count;
}


# Halfassedly extract values from a plist.
#
sub plist_kludge($) {
  my ($plist) = @_;
  my $result = '';

  if ($plist =~ m@^<\?xml@si) {
    $plist =~ s@<string>([^<>]+)</string>@{
      $result .= ($result ? ", " : "") . $1;
      ''}@gsexi;

  } elsif ($plist =~ m@^bplist\d*(.*)@si) {
    #
    # I really don't want to write a decoder for binary plists, and
    # the "Data::Plist::BinaryReader" module doesn't seem to work.
    # So just run "strings" on it, basically.
    #
    $plist = $1;
    $plist =~ s/[\000-\037\200-\377\\%]+/ /gs;
    $plist =~ s/^\s+|\s+$//gsi;
    foreach (split (/\s+/, $plist)) {
      next unless m/^.{8}/s;
      $result .= ($result ? ", " : "") . $_;
    }

  } else {
    print STDERR "$progname: unrecognized plist: $plist\n";
  }
  return $result;
}


# Don't actually need this, I guess?
# There is a second copy of the 'text' field in 'madrid_attributedBody'
# which is an NSArchive object of an NSData of an NSAttributedString.
#
#use Foundation;
#sub nsunarchive($) {
#  my ($data) = @_;
#  $data = NSString->stringWithCString_length_($data, length($data));
#  $data = $data->dataUsingEncoding_(NSString->defaultCStringEncoding);
#  $data = NSUnarchiver->unarchiveObjectWithData_($data);
#  $data = $data->string();
#  $data = $data->cStringUsingEncoding_(NSString->defaultCStringEncoding);
#  return $data;
#}


sub reformat_phone_number($) {
  my ($n) = @_;
  my @r = ();
  foreach (split(/\s*,\s*/, $n)) {
    s/^tel://gs;
    s/^\+//s;
    s/[-.()_\s]//gs           # "(415) 555-1212"   ==>  "4155551212".
      unless m/[@]/s;
    s/^1(\d{10})$/$1/s;       # "+1 415 555 1212"  ==>  "4155551212".
    s@/@@g;                   # some numbers have / in them. BAD!
    push @r, $_;
  }
  return join (', ', @r);
}


sub number_to_name($) {
  my ($n) = @_;
  my @r = ();
  foreach my $n1 (split(/\s*,\s*/, $n)) {
    $n1 = $phone_number_map{$n1};
    push @r, $n1 if $n1;
  }
  return join (', ', @r);
}


sub sms_backup_1($$$) {
  my ($db_file, $idx, $output_dir) = @_;

  print STDERR "$progname: opening $idx $db_file...\n" if ($verbose > 2);

  my $now = time();
  my ($db_dir) = ($db_file =~ m@^(.*)/[^/]+$@s);
  my %attachmentp;
  my %mkdirs;
  $mkdirs{$output_dir} = 1;

  my %attr;
  my $dbh = DBI->connect("dbi:SQLite:dbname=" . $db_file, '', '', \%attr);
  my $sth = $dbh->prepare("SELECT * FROM message");
  error ("sqlite failed: $idx: $db_file") unless $sth;
  $sth->execute();

  my $date = (stat($db_file))[9];
  print STDERR "$progname: $idx: last modified: " . localtime($date) . "\n"
    if ($verbose > 2);

  my %output;

  while (my $h = $sth->fetchrow_hashref()) {

    my $imsgp  = $h->{is_madrid};	# 0 = SMS, 1 = iMessage
    my $flags  = $h->{flags};		# 0 = iMessage, 2 = SMS in, 3 = SMS out
					# 33 = SMS out failure
					# 35 = SMS out failure, retry
					# 129 = SMS deleted
					# 131 = SMS out, invalid recipient
    my $mflags = $h->{madrid_flags};	# bit field, 0b100 = "SMS in"
	                                # UIFlags?? "5 = link, 6 = symbols"
    my $mtype  = $h->{madrid_type}; 	# 0 = msg, 1 = group chat
    my $date   = $h->{date};		# sometimes time_t,
					# sometimes epoch-2001
    my $addr   = $h->{address};
    my $macct  = $h->{madrid_account};
    my $text   = $h->{text};
    my $abody  = $h->{madrid_attributedBody};
    my $subj   = $h->{subject};
    my $head   = $h->{headers};
    my $recip  = $h->{recipients};
    my $room   = $h->{madrid_roomname};

    # SMSes use normal Unix time_t, with epoch = Jan 1, 1970 GMT.
    # iMessages use epoch = Jan 1, 2001 GMT.  WTF!
    #
    # The "service" field is either 'iMessage' or 'SMS', but if it is set
    # at all, then that means the date is of the other epoch.
    #
    $imsgp = 1 if defined ($h->{service});

    # Great news everybody! As of iOS 11, the date is now the number of
    # NANOseconds since the Satanic Anti-Epoch of Jan 1 2001:
    $date /= 1000000000 if ($date > 100000000000000000);

    $date += 978307200 if ($imsgp);

    my @lt = localtime($date);
    print STDERR "$progname: IMPROBABLE YEAR: " . localtime($date) . "\n"
      if ($lt[5] < (2005 - 1900) || $lt[5] > (localtime)[5]);

    if ($subj && $text) { $text = "$subj\n$text"; }
    elsif ($subj && !$text) { $text = $subj; }
    elsif (!defined($text)) { $text = ''; }

    $text = clean_text ($text);

    # Sometimes the 'address' phone number is in an XML blob in 'recipients',
    # for no reason that I can discern, even when there's only one recipient.
    #
    if (!$addr && $recip) {
      $addr = plist_kludge ($recip);
    }

    # In iMessage, the destination is sometimes in madrid_handle instead.
    $addr = $h->{madrid_handle} unless defined $addr;

    if ($mtype && $mtype == 1) {
      my $sth2 = $dbh->prepare("SELECT * FROM madrid_chat" .
                               " WHERE room_name = '$room'" .
                               " LIMIT 1");
      $sth2->execute();
      my $h2 = $sth2->fetchrow_hashref();
      $addr = plist_kludge ($h2->{participants});
    }

    # Hey, let's hide the recipient somewhere else. Great.
    #
    if (!defined($addr)) { 
      my $id = $h->{handle_id};
      if ($id) {
        my $sth2 = $dbh->prepare("SELECT * FROM handle" .
                                 " WHERE ROWID = '$id'" .
                                 " LIMIT 1");
        $sth2->execute();
        my $h2 = $sth2->fetchrow_hashref();
        $addr = $h2->{id};
      }
    }

    # Sometimes I get a message with no recipient, but with an attachment,
    # and cache_roomnames => 'chat257619989216595149'.  No idea what to
    # do with that. I can't find it in any of the other tables.
    #
    $addr = '???' unless defined ($addr);

    # In a multi-recipient chat, move the sender to the front of the list.
    #
    if ($addr =~ m/,/ && $h->{madrid_handle}) {
      my $sender = $h->{madrid_handle};
      $addr =~ s@,\s*\Q$sender@@si;
      $addr =~ s@\Q$sender\E,\s*@@si;
      $addr = "$sender, $addr";
    }

    $addr = reformat_phone_number ($addr);

    $text =~ s/(^\n+|\n+$)//gs;
    $text =~ s/\n/\n\t/gs;             # indent continuation lines


    my @attachments = ();
    my $id = $h->{ROWID};
    if ($h->{cache_has_attachments}) {
      my $sth2 = $dbh->prepare("
        SELECT *
          FROM attachment a, message_attachment_join ma
         WHERE ma.message_id = $id
           AND ma.attachment_id = a.ROWID");
      $sth2->execute();
      while (my $h2 = $sth2->fetchrow_hashref()) {
        my $fn0 = $h2->{filename} || $h2->{transfer_name};

        if (! $fn0 && $h2->{user_info}) {
          # There's also an icloud url in the user_info. Bleh.
          $fn0 = $2 if ($h2->{user_info} =~
                        m@image/(jpeg|png)...?([-_a-zA-Z\d.]+[a-zA-Z\d])@s);
        }

        my $fn = $fn0;
        $fn =~ s@^~/@MediaDomain-@s;
        $fn = "$db_dir/" . sha1_hex($fn);

        # Convert hex subdirs from "foo/XX/YYzzz" to "foo/YY/YYzzz"
        $fn =~ s@/[\da-f]{2}/([\da-f]{2})([\da-f]+)$@/$1/$1$2@si;

        my $desc = $text;
        $desc =~ s/\n.*$/.../s;
        $desc =~ s/^(.{20}).*$/$1.../s;
        $fn0 =~ s@^.*/@@s;
        my $name = number_to_name($addr) || $addr;
        my $t = strftime ("%a %b %d %I:%M %p", localtime($date));
        $desc = "$fn0, $t, $name, \"$desc\"";
        push @attachments, [ $fn, $h2->{transfer_name}, $desc ];
      }
    }

    foreach my $a (@attachments) {
      my $phone_fn  = $a->[0];
      my $pretty_fn = $a->[1] || 'image';
      my $desc      = $a->[2];
      
      my $exts = 'jpg|png|gif|mov|mp3|mp4|m4v|m4a|3gp|amr|ico|vcf';
      $pretty_fn = lc($pretty_fn);
      $pretty_fn =~ s/[^-+a-z0-9.:+]//gs;	# Sanitize
      $pretty_fn =~ s/^[-_.]//gs;
      $pretty_fn =~ s/\.jpeg\b/.jpg/gs;		# Spell it right
      $pretty_fn =~ s/(\.($exts))+$/$1/gs;	# One extension is plenty
      $pretty_fn .= '.jpg'			# At least one
        unless ($pretty_fn =~ m/\.($exts)$/s);


      my $year = strftime ("%Y", @lt);
      my $time = strftime ("%m-%d-%H:%M:%S", @lt);
      my $dir = "$output_dir/Attachments";
      $mkdirs{"$dir"} = 1;
      $mkdirs{"$dir/$year"} = 1;

      my $local_fn = "$year/$time-$addr-$pretty_fn";

      $text .= "\n\t" if $text;
      $text .= "<img src=\"$local_fn\">";

      # Don't whine about missing attachments that are more than a couple
      # of weeks old.  They're probably lost forever.
      #
#      my $old_p = ($now - $date > (60 * 60 * 24 * 30 * 2));
      my $old_p = ($now - $date > (60 * 60 * 24 * 15));
      if (!$old_p || -f $phone_fn) {
        $local_fn = "$dir/$local_fn";
        $output{$local_fn} = [ $id, $phone_fn ];
      }
      $attachmentp{$local_fn} = $desc;
    }

    # The "sent/received" flag is stored differently in iMessages versus SMSes.
    # And it changed again in iOS 6.0.
    my $type;
    if (defined ($h->{is_from_me})) {
      $type = ($h->{is_from_me} ? '>' : '<');		# iOS 6.0
    } elsif ($imsgp) {
      $type = (($mflags & (1<<15)) ? '>' : '<');	# iOS 5.0 iMessage
    } else {
      $type = (($flags & 1) ? '>' : '<');		# SMS
    }

    my $timestr = strftime ("%a %b %d %I:%M %p", @lt);

    my $name = number_to_name($addr) || '';
    my $line = "$type $timestr $addr $name \t$text\n";

    my $month_str = strftime ("%Y-%m", @lt);
    $addr =~ s/\s+//gs;
    my $filename = "$output_dir/$month_str.$addr.txt";

    print STDERR "$progname: got: $line\n" if ($verbose > 5);

    my $OP = $output{"$filename"};
    my $of = $OP ? $OP->[1] : '';
    $output{"$filename"} = [ $id, $of . $line ];
  }

  foreach my $d (sort { length($a) cmp length($b) } keys %mkdirs) {
    if (! -d $d) {
      if ($debug_p) {
        print STDERR "$progname: not mkdir $d\n";
      } else {
        print STDERR "$progname: mkdir $d\n" if ($verbose);
        mkdir ($d);
      }
    }
  }

  foreach my $file (sort keys (%output)) {
    my ($mid, $body) = @{$output{$file}};
    write_changes ($file, $idx, $mid, $body, $attachmentp{$file});
  }
}


sub sms_backup($) {
  my ($output_dir) = @_;

  $output_dir =~ s@/+$@@gs;

  # Iterate over each subdirectory in the backup dir, and save SMS messages
  # from every database in those dirs.

  my @dbs = ($addressbook_dir . "AddressBook-v22.abcddb");
  my $dd = $addressbook_dir . "Sources";

  if (opendir (my $dir, $dd)) {
    my @files = sort readdir($dir);
    closedir $dir;
    foreach my $d (@files) {
      next if ($d =~ m/^\./);
      my $f = "$dd/$d/AddressBook-v22.abcddb";
      push @dbs, $f if (-f $f);
    }
  }

  if ($verbose > 2) {
    print STDERR "\n$progname: AddressBook DBs:\n\n";
    foreach my $f (@dbs) {
      print STDERR "  $f\n";
    }
    print STDERR "\n";
  }

  my $count = 0;
  foreach my $f (@dbs) {
    $count += load_addressbook ($f);
  }
  error ("no entries in Address Books") unless $count;


  opendir (my $dir, $iphone_backup_dir) || error ("$iphone_backup_dir: $!");
  my @files = sort readdir($dir);
  closedir $dir;
  @dbs = ();

  my ($xx) = ($sms_db_name =~ m/^(..)/s);
  foreach my $d (@files) {
    next if ($d =~ m/^\./);
    my $f = "$iphone_backup_dir$d/$sms_db_name.mddata";  # iPhone 3.x name
    push @dbs, $f if (-f $f);
    $f = "$iphone_backup_dir$d/$sms_db_name";            # iPhone 4.x name
    push @dbs, $f if (-f $f);
    $f = "$iphone_backup_dir$d/$xx/$sms_db_name";        # iOS 10.x name
    push @dbs, $f if (-f $f);
  }

  if ($verbose > 2) {
    print STDERR "\n$progname: SMS DBs:\n\n";
    my $i = 1;
    foreach my $f (@dbs) {
      my $date = strftime ("%Y-%m-%d", localtime ((stat($f))[9]));
      my $f2 = $f;
      $f2 =~ s@^\Q$iphone_backup_dir@@s;
      print STDERR "  $i: $date $f2\n";
      $i++;
    }
    print STDERR "\n";
  }

  my $i = 0;
  foreach my $f (@dbs) {
    sms_backup_1 ($f, ++$i, $output_dir);
  }
}


sub clean_text($) {
  my ($text) = @_;
  $text =~ s/\302\240/ /gs;	# UTF8 nbsp
  $text =~ s/\240/ /gs;      	# ASCII nbsp
  $text =~ s/\357\277\274//gs;	# no idea

  $text =~ s/(^|\t)RE :New Message\b\s*/$1/gs;  # WTF

  return $text;
}


# Ok, it's not really CSV.  Each line in the file begins with > or <
# except that lines beginning with TAB are continuation lines.
#
sub csv_split($) {
  my ($body) = @_;

  $body = clean_text($body);
  $body =~ s/^([<>] )/\001$1/gm;
  my @lines = split (/\001/, $body);
  shift @lines; # lose first blank line
  return @lines;
}


sub write_changes($$$$$) {
  my ($file, $idx, $mid, $nbody, $attachment_p) = @_;

  if ($attachment_p) {
    if (open (my $in, '<:raw', $nbody)) {
      local $/ = undef;  # read entire file
      my $body2 = '';
      while (<$in>) { $body2 .= $_; }
      close $in;

      if (-f $file) {
        print STDERR "$progname: $idx: exists: $file\n"
          if ($verbose > 1 && !$debug_p);
      } elsif ($debug_p) {
        print STDERR "$progname: $idx: not writing $file\n";
      } else {
        open (my $out, '>:raw', $file) || error ("$file: $!");
        print $out $body2;
        close $out;
        my $b = length($body2);
        print STDERR "$progname: $idx: wrote $file ($b bytes)\n"
          if ($verbose);
      }
    } else {
      print STDERR "$progname: $idx: $mid: missing attachment:" .
        "\n\t \"$nbody\"" .
        "\n\t for $file:" .
        "\n\t$attachment_p\n" .
        "\n";
    }
    return;
  }

  sub trimline($) {
    my ($line) = @_;
    # Work around a now-fixed bug where old files had botched the
    # date's minute (had written it as %m (month) instead of %M...)
    $line =~ s/^(.{16})../$1__/s;

    # Repair old, improperly trimmed phone numbers.
    $line =~ s%^(.{22})([^\s]+)%{ $1 . reformat_phone_number($2); }%sex;

    return $line;
  }

  my @obody = ();
  my %olines;
  my $count = 0;
  my $count2 = 0;
  if (open (my $in, '<', $file)) {
    local $/ = undef;  # read entire file
    my $obody = <$in>;
    close $in;
    @obody = csv_split ($obody);
    foreach my $line (@obody) {
      $count++;
      $olines{trimline($line)} = 1;
    }
  }

  my @nlines = ();
  foreach my $line (csv_split ($nbody)) {
    if (! $olines{trimline($line)}) {
      $count++;
      $count2++;
      push @nlines, $line;
    }
  }

  my $repair_attachments_p = 0;   # Here be monsters

  if ($repair_attachments_p) {
    my $obody = join("", @obody);
    foreach my $line (csv_split ($nbody)) {
      if ($line =~ m/^(.{16})..(.+?)(\t<img.*)$/s) {
        my ($a, $b) = ($1, $2);
        my $ok = 0;
        foreach my $oline (@obody) {
          if ($oline =~ m/\Q$a\E..\Q$b\E\t?$/s) {
            $oline = $line;
            $ok = 1;
            last;
          }
        }
        print STDERR "#### $file: missed $line\n\t[$a..$b]\n"
          unless $ok;
      }
    }

    $nbody = join ("", @obody);
    if ($obody ne $nbody) {
      if ($debug_p) {
        open (my $out, '>', "/tmp/a") || error ("$file: $!");
        print $out $nbody;
        close $out;
        my $cmd = "diff -U1 '$file' /tmp/a";
        print STDERR "#### $cmd\n";
        system ($cmd);
      } else {
        open (my $out, '>', $file) || error ("$file: $!");
        print $out $nbody;
        close $out;
        print STDERR "$progname: overwrote $file\n";
      }
    }

    return;
  }


  my ($year, $mon) = ($file =~ m@/(\d\d\d\d)-(\d\d)\.[^/]+$@);
  my @now = localtime(time);
  my $now = (($now[5] + 1900) * 10000 + $now[4]);
  my $then = ($year * 10000 + $mon);
  my $old_p = ($now - $then) > 2;

  # NOTE: As a sanity-check, we refuse to append SMS messages to any file
  # that is more than a few months old.  This is because sometimes the
  # date-stamps on old SMSes shifts slightly; and also because if you have
  # changed or deleted the address-book name associated with that phone
  # number, the line will show as "different".  (E.g., if someone changed
  # their phone number and you deleted the old number from the address book.)
  #
  # However, if the SMS is old, but the file doesn't exist at all, we write
  # the file anyway, under the assumption that this is the first run, and
  # we're populating the directory with a bunch of old SMSes for the first
  # time.
  #
  $old_p = 0 if (! -f $file);


  my @nbody = @obody;

  my $f2 = $file;
  $f2 =~ s@^.*/@@gs;
  foreach (@nlines) {
    if ($verbose > 2 && $#obody >= 0) {
      print STDERR "$f2: + $_";
    }
    push @nbody, $_;
  }


#  open (my $out, '>', "/tmp/a") || error ("$file: $!");
#  print $out join ("", @nbody);
#  close $out;
#  my $cmd = "diff -U0 '$file' /tmp/a";
#  print STDERR "#### $cmd\n";
#  system ($cmd);


  if ($#nlines < 0) {
    if ($verbose > 1) {
      $file =~ s@^.*/@@;
      print STDERR "$progname: $file: unchanged\n";
    }
  } else {

    my ($file_year) = ($file =~ m@/(\d{4})-\d\d\.[^/]+$@si);
    error ("unparsable file name: $file") unless ($file_year > 2000);

    # Sort lines numerically.
    my $dateof = sub($) {
      my ($line) = @_;
      my ($d) = ($line =~ m/^..(.{19})/s);
      $d = "$d $file_year";  # So that Feb 29 is parsable, of all things.
      my $d2 = str2time($d) || error ("unparsable time: $d");
      return $d2;
    };
    @nbody = sort { $dateof->($a) <=> $dateof->($b) } @nbody;

    if (! ($debug_p || $old_p)) {
      open (my $out, '>', $file) || error ("$file: $!");
      print $out join ("", @nbody);
      close $out;
    }

    if ($verbose) {
      $file =~ s@^.*/@@;
      print STDERR ("$progname: " .
                    (($debug_p || $old_p) ? "didn't write" : "wrote") .
                    ($old_p ? " old file" : "") .
                    " $file ($count2 of $count lines)\n");
    }
  }
}


sub error($) {
  my ($err) = @_;
  print STDERR "$progname: $err\n";
  exit 1;
}

sub usage() {
  print STDERR "usage: $progname [--verbose] [--debug] output-dir\n";
  exit 1;
}

sub main() {
  my $output_dir = undef;
  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if ($_ eq "--verbose") { $verbose++; }
    elsif (m/^-v+$/) { $verbose += length($_)-1; }
    elsif ($_ eq "--debug") { $debug_p++; }
    elsif (m/^-./) { usage; }
    elsif (! $output_dir) { $output_dir = $_; }
    else { usage; }
  }

  $verbose += 3 if ($debug_p);

  $output_dir = "$ENV{HOME}/Documents/SMS Backup"
    unless $output_dir;

  sms_backup ($output_dir);
}

main();
exit 0;
