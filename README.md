![Kingdom picture](https://github.com/flut2/kingdom/blob/main/kingdom.png?raw=true)

**Requirements:**
- A Redis-compatible server running (or Dragonfly if toggled on in the server build options)
- Zig 0.14.0

**Usage:**

Should work on localhost without any changes, just compile and run the server and the client. First user to register is automatically ranked Admin.
To expose the server to other people, head into ``server/src/settings.zig`` and ``client/build.zig`` and change the relevant IPs (``public_ip``, ``login_server_uri``), with the latter being optional (can also specify it as a build option).
