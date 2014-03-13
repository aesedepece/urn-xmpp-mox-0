
  https://github.com/waalt/urn-xmpp-mox-0
  XEP-xxxx: Money Over XMPP (MOX)

Installing instructions for Prosody
=====

Dependencies
===
  * At least one working **BitcoinAPI** server (*bitcoind*, *litecoind*, 
  *dogecoind*...) accepting [RPC-JSON]
  (https://en.bitcoin.it/wiki/API_reference_%28JSON-RPC%29) queries.
  * **curl**

Installing
===
  1. Copy the ```mod_mox.lua``` file into your Prosody modules directory, 
  usually ```/usr/lib/prosody/modules/```.
  2. Enable the module by adding the following line inside to the 
  ```modules_enabled``` section in ```/etc/prosody/prosody.cfg.lua```:
  
```lua
                "mox"; -- Money Over XMPP
```

Configuring
===
  1. Append the following code block in your Prosody main or site-specific 
  configuration file, usually ```/etc/prosody/prosody.cfg.lua```:
  
```lua
------ MOX Providers ------
mox_servers = {
        bitcoin = {"127.0.0.1", "8332", "bitcoinrpc", 
        "A8frhfUUc3kKEBmdcf1w1gX15roXhpDuaUkaTZifkwvt"}
}
```
  2. Change the parameters according to your RPC-JSON setup. You MAY add as many
   currencies as you want. The currency name MUST be written in lower case.

Disclaimer
===
This implementation is EXPERIMENTAL and you SHOULD NOT use it in production 
environments. If you want to play with it, we recommend you to make the first 
tests in a [Testnet setup](https://en.bitcoin.it/wiki/Testnet).
