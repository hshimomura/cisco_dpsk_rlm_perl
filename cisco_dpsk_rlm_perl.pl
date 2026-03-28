#
# Cisco EasyPSK helper for FreeRADIUS rlm_perl
#
# Purpose:
# - Read Cisco-AVPair values from the Access-Request
# - Extract binary-safe values for:
#   - cisco-anonce
#   - cisco-8021x-data
#   - cisco-bssid
# - Populate request attributes expected by the dpsk module:
#   - FreeRADIUS-802.1X-Anonce
#   - FreeRADIUS-802.1X-EAPoL-Key-Msg
#   - Called-Station-MAC (overridden with cisco-bssid)
# - In post-auth, convert reply:Pre-Shared-Key to PMK hex and return:
#   - Cisco-AVPair = "psk=<hex>"
#   - Cisco-AVPair = "psk-mode=hex"
#

use strict;
use warnings;
use Digest::SHA qw(hmac_sha1);

use vars qw(
	%RAD_REQUEST
	%RAD_REPLY
	%RAD_CHECK
	%RAD_CONFIG
	$RLM_MODULE_NOOP
	$RLM_MODULE_OK
	$RLM_MODULE_UPDATED
);

my $EASYPSK_ERR_UNSPECIFIED = 1;
my $EASYPSK_ERR_PASSWORD_MISMATCH = 2;
my $EASYPSK_ERR_BAD_FRAME = 5;
my $EASYPSK_ERR_MISSING_PARAM = 6;

sub _decode_radius_escaped_string {
	my ($value) = @_;
	my $out = '';

	pos($value) = 0;
	while (pos($value) < length($value)) {
		if ($value =~ /\G\\([0-7]{1,3})/gc) {
			$out .= chr(oct($1));
			next;
		}

		if ($value =~ /\G\\([nrt\\"])/gc) {
			my %map = (
				'n'  => "\n",
				'r'  => "\r",
				't'  => "\t",
				'\\' => '\\',
				'"'  => '"',
			);
			$out .= $map{$1};
			next;
		}

		if ($value =~ /\G(.)/gcs) {
			$out .= $1;
			next;
		}
	}

	return $out;
}

sub _hexify {
	my ($data) = @_;
	return unpack('H*', $data);
}

sub _values_for {
	my ($attr, $hashref) = @_;
	$hashref ||= \%RAD_REQUEST;
	return () unless exists $hashref->{$attr};

	my $v = $hashref->{$attr};
	return ref($v) eq 'ARRAY' ? @$v : ($v);
}

sub _pbkdf2_hmac_sha1 {
	my ($passphrase, $salt, $iterations, $dk_len) = @_;
	my $hash_len = 20;
	my $blocks = int(($dk_len + $hash_len - 1) / $hash_len);
	my $derived = '';

	for my $block_index (1 .. $blocks) {
		my $u = hmac_sha1($salt . pack('N', $block_index), $passphrase);
		my $t = $u;

		for (2 .. $iterations) {
			$u = hmac_sha1($u, $passphrase);
			$t ^= $u;
		}

		$derived .= $t;
	}

	return substr($derived, 0, $dk_len);
}

sub _set_error_cause {
	my ($code) = @_;
	$RAD_CHECK{'Tmp-String-0'} = $code;
}

sub authorize {
	my $anonce;
	my $eapol;
	my $bssid_hex;
	my $ssid;

	foreach my $pair (_values_for('Cisco-AVPair')) {
		my $raw = _decode_radius_escaped_string($pair);

		if (index($raw, 'cisco-anonce=') == 0) {
			$anonce = substr($raw, length('cisco-anonce='));
			next;
		}

		if (index($raw, 'cisco-8021x-data=') == 0) {
			$eapol = substr($raw, length('cisco-8021x-data='));
			next;
		}

		if (index($raw, 'cisco-bssid=') == 0) {
			my $bssid = substr($raw, length('cisco-bssid='));
			$bssid =~ s/[^0-9A-Fa-f]//g;
			$bssid_hex = lc($bssid) if length($bssid) == 12;
			next;
		}

		if (index($raw, 'cisco-wlan-ssid=') == 0) {
			$ssid = substr($raw, length('cisco-wlan-ssid='));
			next;
		}
	}

	foreach my $value (_values_for('Called-Station-SSID')) {
		$ssid = $value;
		last if defined $ssid;
	}

	if (!defined($anonce) || !defined($eapol) || !defined($bssid_hex) || !defined($ssid)) {
		_set_error_cause($EASYPSK_ERR_MISSING_PARAM);
		return $RLM_MODULE_NOOP;
	}

	if (length($eapol) < 99) {
		_set_error_cause($EASYPSK_ERR_BAD_FRAME);
		return $RLM_MODULE_NOOP;
	}

	$RAD_REQUEST{'FreeRADIUS-802.1X-Anonce'} = '0x' . _hexify($anonce);
	$RAD_REQUEST{'FreeRADIUS-802.1X-EAPoL-Key-Msg'} = '0x' . _hexify($eapol);
	$RAD_REQUEST{'Called-Station-MAC'} = '0x' . $bssid_hex;

	return 2;
}

sub post_auth {
	my $psk;
	my $ssid;
	my $identity;
	my @avpairs = _values_for('Cisco-AVPair', \%RAD_REPLY);

	foreach my $value (_values_for('Pre-Shared-Key', \%RAD_REPLY)) {
		$psk = $value;
	}

	foreach my $value (_values_for('PSK-Identity', \%RAD_REPLY)) {
		$identity = $value;
		last if defined $identity;
	}

	foreach my $value (_values_for('Called-Station-SSID')) {
		$ssid = $value;
		last if defined $ssid;
	}

	if (!defined($psk) || !defined($ssid)) {
		my $code = $RAD_CHECK{'Tmp-String-0'};
		if (!defined($code) && (($RAD_CHECK{'Auth-Type'} || '') eq 'dpsk' || ($RAD_CONFIG{'Auth-Type'} || '') eq 'dpsk')) {
			$code = $EASYPSK_ERR_PASSWORD_MISMATCH;
		}
		$code ||= $EASYPSK_ERR_UNSPECIFIED;

		@avpairs = grep { $_ !~ /^cisco-easy-psk-error-cause=/ } @avpairs;
		push @avpairs, 'cisco-easy-psk-error-cause=' . $code;
		$RAD_REPLY{'Cisco-AVPair'} = \@avpairs;
		return 2;
	}

	my $pmk_hex = _hexify(_pbkdf2_hmac_sha1($psk, $ssid, 4096, 32));

	@avpairs = grep { $_ !~ /^psk=/ && $_ ne 'psk-mode=hex' && $_ !~ /^cisco-easy-psk-error-cause=/ } @avpairs;
	push @avpairs, 'psk=' . $pmk_hex;
	push @avpairs, 'psk-mode=hex';
	$RAD_REPLY{'Cisco-AVPair'} = \@avpairs;

	if (defined $identity && $identity =~ /^vlan([1-9]\d{0,3})$/i) {
		my $vlan = $1;
		if ($vlan >= 1 && $vlan <= 4094) {
			$RAD_REPLY{'Tunnel-Type'} = 'VLAN';
			$RAD_REPLY{'Tunnel-Medium-Type'} = 'IEEE-802';
			$RAD_REPLY{'Tunnel-Private-Group-Id'} = $vlan;
		}
	}

	return 2;
}

1;
