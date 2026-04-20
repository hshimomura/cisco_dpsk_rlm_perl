# Current notes on DPSK / EasyPSK implementation in FreeRADIUS 3.2.x

This note captures what was learned while testing:
- Cisco Catalyst 9800 EasyPSK
- Meraki iPSK / EasyPSK-style requests
- Ruckus DPSK
- FreeRADIUS 3.2.x with `rlm_dpsk`

The goal is to document the shape that works **now**, even if some parts are still better candidates for later upstream implementation in C.

## Main lessons learned

## 1. `rlm_dpsk` should stay vendor-neutral

The cleanest split is:
- vendor-specific request normalization before `rlm_dpsk`
- generic key matching inside `rlm_dpsk`
- vendor-specific reply formatting in policy

That keeps `rlm_dpsk` reusable across Cisco, Meraki, and Ruckus.

## 2. Current `rlm_dpsk` can now expose enough reply attributes

The useful reply attributes are now:
- `reply:Pairwise-Master-Key`
- `reply:PSK-Identity`
- `reply:Pre-Shared-Key`

This is important because it lets local policy build vendor-specific reply attributes without forcing those formats into the module.

## 3. Optional VLAN assignment belongs in generic reply attributes

The useful CSV format is now:

```text
identity,psk[,mac[,vlanid]]
```

If `vlanid` is present, `rlm_dpsk` returns standard tunnel reply attributes:
- `Tunnel-Type = VLAN`
- `Tunnel-Medium-Type = IEEE-802`
- `Tunnel-Private-Group-Id = "<vlanid>"`

That is better than hard-coding vendor-specific VLAN reply formats in the module.

## 4. Cisco request parsing is the awkward part

Cisco EasyPSK carries required request data in `Cisco-AVPair`, including binary payloads.

The request-side problem is not the matching logic itself. The real problem is safely decoding:
- `cisco-anonce`
- `cisco-8021x-data`
- `cisco-bssid`
- `cisco-wlan-ssid`

In FreeRADIUS 3.2.x, a small Perl helper works for lab validation. For a cleaner upstream path, this normalization should eventually move into `rlm_preprocess` in C.

## 5. Cisco reply formatting does not need to live in Perl

Once `reply:Pre-Shared-Key` is exposed, Cisco reply formatting can be done in policy:

```text
update reply {
	&Cisco-AVPair += "psk=%{reply:Pre-Shared-Key}"
	&Cisco-AVPair += "psk-mode=ascii"
}
```

That is simpler than having Perl generate the final Cisco reply.

## 6. `rlm_perl` is acceptable for exploration, not ideal as the final upstream home

`rlm_perl` was useful to prove:
- what Cisco fields are required
- how Cisco escaped AVPairs should be decoded
- which generic attributes must be populated

But for maintainability and robustness, the better long-term home for Cisco request normalization is a C implementation in a preprocessing layer.

## Recommended configuration items

## Module configuration

Example `mods-available/dpsk`:

```text
dpsk {
	ruckus = no
	cache_size = 1024
	cache_lifetime = 86400
	filename = /etc/freeradius/mods-config/dpsk/psk.csv
}
```

Example `mods-available/cisco_easy_psk_perl`:

```text
perl cisco_easy_psk_perl {
	filename = /etc/freeradius/mods-config/perl/cisco_easy_psk_perl.pl
	func_authorize = authorize
}
```

## Client settings

If the vendor sends `Message-Authenticator`, require it.

For example, when Ruckus already sends it, the client should be configured with:

```text
require_message_authenticator = yes
```

If a device does not send it, that is a separate interoperability decision and should be scoped to that client only.

## `psk.csv`

Useful examples:

```text
00220022,00220022
vlan2065,00330033,,2065
00550055,00550055,a0d36578f384
00660066,00660066,f44ee3989fe0
```

Notes:
- `identity,psk` works
- `identity,psk,mac` works
- `identity,psk,,2065` works
- `identity,psk,mac,2065` works
- MAC entries must be 12 hex characters

## Sample `policy.d/dpsk`

```text
ruckus_dpsk {
	if (&Ruckus-SSID && &Ruckus-BSSID && (&Ruckus-DPSK-Cipher == 4) && &Ruckus-DPSK-Anonce && &Ruckus-DPSK-EAPOL-Key-Frame) {
		update request {
			&Called-Station-SSID := &Ruckus-SSID
			&Called-Station-MAC := &Ruckus-BSSID
			&FreeRADIUS-802.1X-Anonce := &Ruckus-DPSK-Anonce
			&FreeRADIUS-802.1X-EAPoL-Key-Msg := &Ruckus-DPSK-EAPOL-Key-Frame
		}
		updated
	}
	else {
		noop
	}
}

ruckus_dpsk_reply {
	if (&Ruckus-SSID && &reply:Pairwise-Master-Key) {
		update reply {
			&MS-MPPE-Recv-Key := &reply:Pairwise-Master-Key
		}
		updated
	}
	else {
		noop
	}
}

meraki_easy_psk {
	if (&Meraki-IPSK-SSID && &Meraki-IPSK-BSSID && &Meraki-IPSK-Anonce && &Meraki-IPSK-EAPOL) {
		update request {
			&Called-Station-SSID := &Meraki-IPSK-SSID
			&Called-Station-MAC := &Meraki-IPSK-BSSID
			&FreeRADIUS-802.1X-Anonce := &Meraki-IPSK-Anonce
			&FreeRADIUS-802.1X-EAPoL-Key-Msg := &Meraki-IPSK-EAPOL
		}
		updated
	}
	else {
		noop
	}
}

meraki_easy_psk_reply {
	if (&Meraki-IPSK-SSID && &reply:Pre-Shared-Key) {
		update reply {
			&Tunnel-Password := &reply:Pre-Shared-Key
		}
		updated
	}
	else {
		noop
	}
}

cisco_easy_psk {
	if (&Cisco-AVPair[*]) {
		cisco_easy_psk_perl
	}
	else {
		noop
	}
}

cisco_easy_psk_reply {
	if (&request:Cisco-AVPair[*] && &reply:Pre-Shared-Key) {
		update reply {
			&Cisco-AVPair += "psk=%{reply:Pre-Shared-Key}"
			&Cisco-AVPair += "psk-mode=ascii"
		}
		updated
	}
	else {
		noop
	}
}
```

## Sample call flow in `sites-enabled/default`

A practical shape is:

```text
authorize {
	...
	rewrite_called_station_id
	ruckus_dpsk
	meraki_easy_psk
	cisco_easy_psk
	dpsk
	...
}

authenticate {
	...
	Auth-Type dpsk {
		dpsk
		if (updated) {
			ok
		}
	}
	...
}

post-auth {
	...
	ruckus_dpsk_reply
	meraki_easy_psk_reply
	cisco_easy_psk_reply
	...
}
```

## Notes by vendor

## Ruckus

What worked well:
- request normalization in policy
- reply formatting from `reply:Pairwise-Master-Key`

Observed reply pattern:
- `MS-MPPE-Recv-Key := &reply:Pairwise-Master-Key`

## Meraki

What worked well:
- request normalization in policy
- reply formatting from `reply:Pre-Shared-Key`
- optional VLAN tunnel reply attributes can coexist with Meraki-specific reply attributes

Observed reply pattern:
- `Tunnel-Password := &reply:Pre-Shared-Key`

## Cisco Catalyst 9800 EasyPSK

What worked well:
- request normalization in Perl
- reply formatting in policy
- optional VLAN tunnel reply attributes from the updated `rlm_dpsk`

Observed request-side requirements:
- decode escaped `Cisco-AVPair`
- extract `cisco-anonce`
- extract `cisco-8021x-data`
- override `Called-Station-MAC` with `cisco-bssid`
- keep `Called-Station-SSID` aligned with `cisco-wlan-ssid`

Observed reply pattern:
- `Cisco-AVPair += "psk=%{reply:Pre-Shared-Key}"`
- `Cisco-AVPair += "psk-mode=ascii"`

## What should likely happen next in FreeRADIUS itself

If this work were carried further upstream, the next logical step would be:
- keep `rlm_dpsk` generic
- keep vendor reply formatting in policy
- move Cisco request normalization from Perl into `rlm_preprocess` in C

That would preserve the working architecture discovered here while avoiding a Perl dependency for Cisco request parsing.
