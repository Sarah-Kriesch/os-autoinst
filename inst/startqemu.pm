#!/usr/bin/perl -w
use strict;
use File::Path qw/mkpath/;

my $basedir="raid";
my $qemuimg="/usr/bin/kvm-img";
if(!-e $qemuimg) {$qemuimg="/usr/bin/qemu-img"}

my $qemubin = $ENV{'QEMU'};
unless ($qemubin) {
	for my $bin (map { '/usr/bin/'.$_ } qw/kvm qemu-kvm qemu/) {
		next unless -x $bin;
		$qemubin = $bin;
		last;
	}
	die "no Qemu/KVM found\n" unless $qemubin;
}

my $iso=$ENV{ISO};
my $sizegb=8;
if($ENV{BTRFS}) {$sizegb=10}
$ENV{HDDMODEL}||="virtio";
$ENV{NICMODEL}||="virtio";
$ENV{QEMUVGA}||="cirrus";
$ENV{QEMUCPUS}||=1;
$ENV{NUMDISKS}||=2;
if(defined($ENV{RAIDLEVEL})) {$ENV{NUMDISKS}=4}
my @cdrom=("-cdrom", $iso);

$ENV{QEMU_AUDIO_DRV}="wav";
$ENV{QEMU_WAV_PATH}="/dev/null";

if ($ENV{UEFI} && !-e $ENV{UEFI_BIOS_DIR}.'/bios.bin') {
	die "'$ENV{UEFI_BIOS_DIR}/bios.bin' missing, check UEFI_BIOS_DIR\n";
}

mkpath($basedir);

if($ENV{UPGRADE} && !$ENV{LIVECD}) {
	my $file=$ENV{UPGRADE};
	if(!-e $file) {die "'$ENV{UPGRADE}' should be old img.gz"}
	$ENV{KEEPHDDS}=1;
	# use qemu snapshot/cow feature to work on old image without writing it
	unlink "$basedir/l1";
	unlink "$basedir/1";
	#system($qemuimg, "create", "-b", $file, "-f", "qcow2", "$basedir/l1");
	system(qw"cp -a", $file, "$basedir/l1"); # reduce disk IO later
	for my $i (2..$ENV{NUMDISKS}) {
		system($qemuimg, "create" ,"$basedir/$i", "-f", "qcow2", $sizegb."G");
	}
}

if(!$ENV{KEEPHDDS} && !$ENV{SKIPTO}) {
	# fresh HDDs
	for my $i (1..4) {
		unlink("$basedir/l$i");
		if(-e "$basedir/$i.lvm") {
			symlink("$i.lvm","$basedir/l$i");
			system("/bin/dd", "if=/dev/zero", "count=1", "of=$basedir/l1"); # for LVM
		} else {
			system($qemuimg, "create" ,"$basedir/$i", "-f", "qcow2", $sizegb."G");
			symlink($i,"$basedir/l$i");
		}
	}
	if($ENV{USBBOOT}) {
		$ENV{NUMDISKS}=2;
		system("dd", "if=$iso", "of=$basedir/l1", "bs=1M", "conv=notrunc");
		@cdrom=();
	}
}

for my $i (1..4) { # create missing symlinks
	next if -e "$basedir/l$i";
	next unless -e "$basedir/$i";
	symlink($i,"$basedir/l$i");
}
$self->{'pid'}=fork();
die "fork failed" if(!defined($self->{'pid'}));
if($self->{'pid'}==0) {
	my @params=($qemubin, qw(-m 1024 -net user -monitor), "tcp:127.0.0.1:$ENV{QEMUPORT},server,nowait", "-net", "nic,model=$ENV{NICMODEL},macaddr=52:54:00:12:34:56", "-serial", "file:serial0", "-soundhw", "ac97", "-vga", $ENV{QEMUVGA}, "-S");
	if ($ENV{LAPTOP}) {
	    for my $f (<$ENV{LAPTOP}/*.bin>) {
		push @params, '-smbios', "file=$f";
	    }
	}

	for my $i (1..$ENV{NUMDISKS}) {
		my $boot="";#$i==1?",boot=on":""; # workaround bnc#696890
		push(@params, "-drive", "file=$basedir/l$i,cache=unsafe,if=$ENV{HDDMODEL}$boot");
	}
	push(@params, "-boot", "dc", @cdrom) if($iso);
	if($ENV{VNC}) {
		if($ENV{VNC}!~/:/) {$ENV{VNC}=":$ENV{VNC}"}
		push(@params, "-vnc", $ENV{VNC});
		push(@params, "-k", $ENV{VNCKB}) if($ENV{VNCKB});
	}
	if($ENV{QEMUCPU}) { push(@params, "-cpu", $ENV{QEMUCPU}); }
	if($ENV{UEFI}) { push(@params, "-L", $ENV{UEFI_BIOS_DIR}); }
	if($ENV{MULTINET}) {push(@params, qw"-net nic,vlan=1,model=virtio,macaddr=52:54:00:12:34:57 -net none,vlan=1")}
	push(@params, "-usb", "-usbdevice", "tablet");
	push(@params, "-smp", $ENV{QEMUCPUS});
	push(@params, "-enable-kvm");
	if(-e "/usr/bin/eatmydata") { unshift(@params, "/usr/bin/eatmydata") }
	bmwqemu::diag("starting: ".join(" ", @params));
	exec(@params);
	die "exec $qemubin failed";
}
open(my $pidf, ">", $self->{'pidfilename'}) or die "can not write ".$self->{'pidfilename'};
print $pidf $self->{'pid'},"\n";
close $pidf;
sleep 6; # time to let qemu start

1;
