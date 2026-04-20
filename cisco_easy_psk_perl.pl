use strict;
use warnings;

use vars qw(
	%RAD_REQUEST
	%RAD_REPLY
	%RAD_CHECK
	%RAD_CONFIG
);

use constant {
	RLM_MODULE_NOOP    => 7,
	RLM_MODULE_UPDATED => 8,
};

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

	return RLM_MODULE_NOOP unless defined($anonce) && defined($eapol) && defined($bssid_hex) && defined($ssid);
	return RLM_MODULE_NOOP if length($eapol) < 99;

	$RAD_REQUEST{'FreeRADIUS-802.1X-Anonce'} = '0x' . _hexify($anonce);
	$RAD_REQUEST{'FreeRADIUS-802.1X-EAPoL-Key-Msg'} = '0x' . _hexify($eapol);
	$RAD_REQUEST{'Called-Station-MAC'} = '0x' . $bssid_hex;
	$RAD_REQUEST{'Called-Station-SSID'} = $ssid;

	return RLM_MODULE_UPDATED;
}

1;
