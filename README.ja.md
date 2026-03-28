# Cisco EasyPSK 用 FreeRADIUS `rlm_perl` ヘルパー

Cisco WLC の EasyPSK を FreeRADIUS 3.2.x で扱うための Perl モジュールです。

また、本プロジェクトで検証した範囲では、Cisco Identity Services Engine (ISE) 3.5 Patch 2 ではここで必要な EasyPSK 動作を実現できなかったため、FreeRADIUS 側での拡張が必要でした。

この実装は `rlm_dpsk` を補助し、以下を行います。

- `Cisco-AVPair` から EasyPSK 用パラメータを binary-safe に抽出
- `cisco-bssid` を `Called-Station-MAC` に反映
- Access-Accept で `psk=<PMK hex>` と `psk-mode=hex` を返却
- `PSK-Identity` が `vlanNNN` の場合のみ VLAN 属性を返却
- Access-Reject で `cisco-easy-psk-error-cause` を返却

## 目的

このリポジトリは、Cisco EasyPSK を FreeRADIUS で試験する目的で、組み込みの `dpsk` module を補助する Perl 拡張モジュールを実装したものです。

用途はあくまで試験、検証、相互接続確認、小規模なラボ用途です。本格運用におけるスケールや大規模環境での性能を保証するものではありません。

## ソリューションガイドと対象範囲

この実装および本 README の説明は、以下の資料を前提にまとめています。

- Cisco EasyPSK 設定ガイド:
  https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/17-6/config-guide/b_wl_17_6_cg/m_epsk.html
- Cisco EasyPSK Deployment Guide:
  https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/technical-reference/easy-psk-deployment-guide.html
- Cisco WPA3 / iPSK 関連資料:
  https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/17-18/config-guide/b_wl_17_18_cg/m_wpa3.html
- Cisco private PSK / iPSK 関連資料:
  https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/17-6/config-guide/b_wl_17_6_cg/m_pvt_psk_ewlc.html
- FreeRADIUS `dpsk` module リファレンス:
  https://www.freeradius.org/documentation/freeradius-server/4.0.0/reference/raddb/mods-available/dpsk.html

整理すると:

- iPSK は WPA3、FlexConnect、6 GHz を意識する場合により適しています。
- EasyPSK は WPA2 限定の互換性機能であり、Wi‑Fi 6E / 6 GHz には適しません。
- 本実装は `rlm_dpsk` に候補 PSK を順に照合させるため、候補数が増えるほどスケールに制約があります。

## この実装が必要な理由

Cisco Catalyst 9800 WLC の EasyPSK では、認証に必要な値が主に `Cisco-AVPair` で送られます。

- `cisco-anonce`
- `cisco-8021x-data`
- `cisco-bssid`
- `cisco-wlan-ssid`

このうち `cisco-8021x-data` はバイナリを含むため、単純な `unlang` の regex では安全に扱えません。
そのため Perl で escape を復元し、`rlm_dpsk` が必要とする属性へ変換しています。

## 配置ファイル

- `cisco_dpsk_rlm_perl.pl`
- `README.md`
- `README.ja.md`
- `LICENSE`

## 確認できている動作

`radiusd -X` で次を確認済みです。

- EasyPSK の認証成功
- Access-Accept で
  - `Cisco-AVPair += "psk=<64桁hex>"`
  - `Cisco-AVPair += "psk-mode=hex"`
  を返却
- `PSK-Identity` が `vlanNNN` のときだけ VLAN 属性を返却
- パスワード不一致時に
  - `Cisco-AVPair += "cisco-easy-psk-error-cause=2"`
  を返却

## テスト環境

このリポジトリで説明している相互接続確認は、以下の環境で実施しました。

- FreeBSD 14
- FreeRADIUS 3.2.8
- FreeRADIUS 設定ファイルのルートは `/usr/local/etc/raddb`

- Cisco Catalyst 9800 Wireless LAN Controller
- Version `17.18.2`

パスに関する補足:

- この README の設定例が `/usr/local/etc/raddb` で始まるのは、テスト環境が FreeBSD だったためです。
- 一般的な Linux 環境では `/etc/raddb` を使う構成があります。
- Ubuntu の FreeRADIUS 3 パッケージでは `/etc/freeradius/3.0` が一般的です。

## この FreeRADIUS 実装における実務上の制約

このリポジトリでは、FreeRADIUS 側で Cisco から渡された handshake 情報を `rlm_dpsk` に渡し、`mods-config/dpsk/psk.csv` の候補 PSK を照合して一致するものを探します。

つまり実装上は、

- 候補 PSK を順に試す
- 候補数が増えるほど応答コストが増える
- 大規模な PSK 一覧には不向き

という性質があります。

そのため、このリポジトリは EasyPSK の検証や互換性確認には有用ですが、大規模環境向けの本格運用ソリューションとして勧めるものではありません。

## インストール先

FreeRADIUS サーバには Perl モジュールを以下へ配置します。

```text
/usr/local/etc/raddb/cisco_dpsk_rlm_perl.pl
```

前提:

- FreeRADIUS 3.2.x
- `rlm_perl`
- `rlm_dpsk`
- Perl の `Digest::SHA`

## FreeRADIUS 設定

このヘルパーのために最低限追加する内容を抜き出すと、次のとおりです。

```text
rewrite_called_station_id
perl_dpsk
dpsk
if (ok || updated) {
	update control {
		&Auth-Type := dpsk
	}
}

Auth-Type dpsk {
	dpsk
	if (updated || ok) {
		ok
	}
}

perl_dpsk

perl_dpsk
```

配置先で整理すると次です。

- `authorize {}`
  - `rewrite_called_station_id`
  - `perl_dpsk`
  - `dpsk`
  - `if (ok || updated) { ... &Auth-Type := dpsk ... }`
- `authenticate {}`
  - `Auth-Type dpsk { dpsk; if (updated || ok) { ok } }`
- `post-auth {}`
  - `perl_dpsk`
- `Post-Auth-Type REJECT {}`
  - `perl_dpsk`

### 1. Perl module 定義

`mods-enabled/perl_dpsk`

```text
perl perl_dpsk {
	filename = /usr/local/etc/raddb/cisco_dpsk_rlm_perl.pl
	func_authorize = authorize
	func_post_auth = post_auth
}
```

### 2. `sites-enabled/default` の `authorize {}`

`rewrite_called_station_id` は残し、その後に `perl_dpsk`、さらに `dpsk` を呼びます。

追加箇所が分かりやすいように、差分形式でも示します。

```diff
 # sites-enabled/default
 authorize {
 	filter_username
 	preprocess
 	chap
 	mschap
 	digest
 
+ 	rewrite_called_station_id
+	perl_dpsk
+	dpsk
+	if (ok || updated) {
+		update control {
+			&Auth-Type := dpsk
+		}
+	}
 
 	suffix
 	eap
 	files
 	sql
 	expiration
 	logintime
 	pap
 }
```

```diff
authorize {
	filter_username
	preprocess
	chap
	mschap
	digest

+	rewrite_called_station_id
+	perl_dpsk
+	dpsk
+	if (ok || updated) {
+		update control {
+			&Auth-Type := dpsk
+		}
+	}

	suffix
	eap
	files
	sql
	expiration
	logintime
	pap
}
```

### 3. `authenticate {}`

`rlm_dpsk` は成功時に `updated` を返すことがあるため、`ok` に変換します。

追加箇所:

```diff
 # sites-enabled/default
 authenticate {
+ 	Auth-Type dpsk {
+ 		dpsk
+		if (updated || ok) {
+			ok
+		}
+ 	}
 }
```

```diff
authenticate {
+	Auth-Type dpsk {
+		dpsk
+		if (updated || ok) {
+			ok
+		}
+	}
}
```

### 4. `post-auth {}`

成功時の `psk` / `psk-mode` / VLAN 返却のために `perl_dpsk` を呼びます。

追加箇所:

```diff
 # sites-enabled/default
 post-auth {
+	perl_dpsk
 
 	if (&User-Name != "anonymous") {
 		sql
 	}
 	exec
 	remove_reply_message_if_eap
 }
```

```diff
post-auth {
+	perl_dpsk

	if (&User-Name != "anonymous") {
		sql
	}
	exec
	remove_reply_message_if_eap
}
```

### 5. `Post-Auth-Type REJECT {}`

reject 時の `cisco-easy-psk-error-cause` を返すため、ここでも `perl_dpsk` を呼びます。

追加箇所:

```diff
 # sites-enabled/default
 Post-Auth-Type REJECT {
 	auth_log
 	sql
 	attr_filter.access_reject
 	eap
+	perl_dpsk
 	remove_reply_message_if_eap
 }
```

```diff
Post-Auth-Type REJECT {
	auth_log
	sql
	attr_filter.access_reject
	eap
+	perl_dpsk
	remove_reply_message_if_eap
}
```

## モジュールの設計

### `authorize`

`Cisco-AVPair` から次を抽出します。

- `cisco-anonce`
- `cisco-8021x-data`
- `cisco-bssid`
- `cisco-wlan-ssid`

そして FreeRADIUS request 属性として次を設定します。

- `FreeRADIUS-802.1X-Anonce`
- `FreeRADIUS-802.1X-EAPoL-Key-Msg`
- `Called-Station-MAC` を `cisco-bssid` で上書き

異常時:

- 必須パラメータ欠落:
  - `cisco-easy-psk-error-cause=6`
- 802.1X フレーム不正:
  - `cisco-easy-psk-error-cause=5`

### `post_auth`

成功時:

- `reply:Pre-Shared-Key`
- `request:Called-Station-SSID`

から次を計算します。

- `PMK = PBKDF2-HMAC-SHA1(passphrase, ssid, 4096, 32)`

そして reply に以下を追加します。

- `Cisco-AVPair = "psk=<PMK hex>"`
- `Cisco-AVPair = "psk-mode=hex"`

reject 時:

- `Auth-Type=dpsk` まで進んで PSK が得られない場合
  - `cisco-easy-psk-error-cause=2`
- それ以外は必要に応じて `1`, `5`, `6`

VLAN:

- `PSK-Identity` が `^vlan([1-9][0-9]{0,3})$`
- かつ数値としての VLAN が `1..4094`

の場合のみ reply に以下を追加します。

- `Tunnel-Type = VLAN`
- `Tunnel-Medium-Type = IEEE-802`
- `Tunnel-Private-Group-Id = <NNN>`

正規表現だけだと `vlan4095` 以上も一致し得るため、モジュール内で数値の範囲チェックを追加し、`1..4094` のときだけ VLAN reply を返しています。

## `psk.csv` の例

配置場所:

```text
/usr/local/etc/raddb/mods-config/dpsk/psk.csv
```

`rlm_dpsk` の CSV 形式は次です。

```text
identity,psk[,mac]
```

このヘルパーでは `identity` の元の意味を変えず、`identity` が `vlanNNN` かつ `NNN` が `1..4094` の場合にだけ、VLAN 属性を追加で返します。それ以外の `identity` は通常どおり扱い、VLAN reply は返しません。

### VLAN あり

```csv
vlan2065,00330033
```

成功時は以下を返します。

```text
Tunnel-Type = VLAN
Tunnel-Medium-Type = IEEE-802
Tunnel-Private-Group-Id = "2065"
Cisco-AVPair += "psk=<64桁hex>"
Cisco-AVPair += "psk-mode=hex"
```

### VLAN なし

```csv
00440044,00440044
```

`rlm_dpsk` が対応する MAC 指定付きの例:

```csv
00440044,00440044,f4-4e-e3-98-9f-e0
```

成功時は以下のみ返します。

```text
Cisco-AVPair += "psk=<64桁hex>"
Cisco-AVPair += "psk-mode=hex"
```

Tunnel 属性は返しません。

### わざと不一致にする例

端末側を `00550055` に設定し、CSV が

```csv
vlan2065,00330033
00440044,00440044
```

だけなら、期待する reject は次です。

```text
dpsk: Failed to find matching PSK or MAC in /usr/local/etc/raddb/mods-config/dpsk/psk.csv
Sent Access-Reject ...
  Cisco-AVPair += "cisco-easy-psk-error-cause=2"
```

## ログで見るべき点

### request 変換が成功しているか

```text
&request:Called-Station-MAC = ... -> '0x845a3edf8cc9'
&request:FreeRADIUS-802.1X-Anonce = ... -> '0x...'
&request:FreeRADIUS-802.1X-EAPoL-Key-Msg = ... -> '0x...'
```

### `dpsk` が一致したか

```text
dpsk: Creating &reply:PSK-Identity and &reply:Pre-Shared-Key
```

### EasyPSK 成功応答

```text
Sent Access-Accept ...
  Cisco-AVPair += "psk=<64桁hex>"
  Cisco-AVPair += "psk-mode=hex"
```

### VLAN 成功応答

```text
Sent Access-Accept ...
  Tunnel-Private-Group-Id = "2065"
  Tunnel-Type = VLAN
  Tunnel-Medium-Type = IEEE-802
```

### パスワード不一致

```text
dpsk: Failed to find matching PSK or MAC in /usr/local/etc/raddb/mods-config/dpsk/psk.csv
Sent Access-Reject ...
  Cisco-AVPair += "cisco-easy-psk-error-cause=2"
```

### CSV 自体が壊れている場合

```text
dpsk: .../psk.csv[0] Failed to find ',' after identity
```

これは password mismatch ではなく、CSV フォーマット異常です。

## 補足

- `radpostauth_pkey` の duplicate error は EasyPSK とは別問題です
- GitHub 公開向けに再利用性を重視するため、このリポジトリは MIT License としています
- ISE 側のサポート状況は今後のリリースで変わる可能性がありますが、本 README は ISE 3.5 Patch 2 時点での検証結果を前提にしています

## iPSK と EasyPSK の違い

### iPSK

Cisco の WPA3 SAE iPSK / private PSK の資料から読み取れる点は次のとおりです。

- iPSK は WLAN の構成手順において MAC filtering を利用し、AAA / RADIUS ポリシーと連携して個別またはグループ単位の鍵を配布します。
- Cisco は WPA3 SAE iPSK を明示的にサポートしています。
- Cisco の WPA3 資料には 6 GHz と SAE/H2E に関する記述があり、iPSK 系は WPA3・6 GHz 世代の要件に追従できます。
- Cisco の private PSK 検証例では、中央認証の FlexConnect シナリオも確認できます。

### EasyPSK

Cisco の EasyPSK 資料から読み取れる点は次のとおりです。

- EasyPSK も WLAN の構成手順において MAC filtering と AAA 連携を前提にしています。
- EasyPSK は WPA2 ベースであり、EasyPSK Deployment Guide では WPA3 非対応と明記されています。
- 6 GHz は WPA3/SAE を前提とするため、EasyPSK は Wi‑Fi 6E / 6 GHz 環境には適しません。
- Cisco の設定ガイドでも EasyPSK は Local Mode、Central Authentication、Central Switching のみに制約されています。

### セキュリティ上の考え方

EasyPSK のようにグループ単位で同じ passphrase を共有する方式では、passphrase が漏えいした場合にそのグループ全体の再設定が必要になります。

したがって、

- 共有 PSK の漏えい時に影響範囲が広い
- ローテーション運用負荷が高い
- 長期的な設計としては iPSK 系のほうが望ましい

という整理になります。
