# redis-client
[![Coverage Status](https://coveralls.io/repos/github/Oozlum/redis-client/badge.svg)](https://coveralls.io/github/Oozlum/redis-client)
[![Build Status](https://travis-ci.com/Oozlum/redis-client.svg?branch=master)](https://travis-ci.com/github/Oozlum/redis-client)

A Redis client library for Lua

## Compatibility
Lua >= 5.1 and LuaJIT.

## Features
- Written in pure Lua.
- Available through luarocks.
- One external dependency.
- Synchronous by default, optionally asynchronous using continuation queues (cqueues).
- A single connection can be shared by multiple co-routines (cqueues).
- Manages transactions.
- Supports redis pub/sub mechanism.
- Easily extensible.
- Allows both low- and high-level protocol use.

## Runtime Dependencies
- [cqueues](https://github.com/wahern/cqueues) >= 20150907

## Installation
redis-client is available via luarocks:
```
$ luarocks install redis-client
```
Alternatively clone the repo and copy the library files directly, for example:
```
$ git clone https://github.com/Oozlum/redis-client
$ cp -r redis-client/redis-client /usr/local/share/lua/5.3
```

## Building and Development
redis-client is written in pure Lua, so there are no build steps required.  However, you may want to use the following tools to check and test any changes:
- [luacheck](https://github.com/mpeterv/luacheck)
- [busted](http://olivinelabs.com/busted/)
- [luacov](https://keplerproject.github.io/luacov/)

```
$ luacheck .
$ busted -c && luacov && less luacov.report.out
```

## Usage
redis-client is split into four modules which provide functionality at increasingly higher levels:
- [redis-client.protocol](#redis-clientprotocol) handles the encoding/decoding of messages between redis server and client.
- [redis-client.response](#redis-clientresponse) deals with formatting of the data returned by the redis server.
- [redis-client.redis](#redis-clientredis) manages the network communications and synchronisation between multiple users (co-routines) of a single client connection.
- [redis-client](#redis-client) performs high-level transaction handling, validation of commands and command-dependent response manipulation.

### Error Handling
There are two types of errors within this library: soft- and hard errors.  A soft error is one that is reported by the redis server itself -- there was no error within the library or the protocol, but the server didn't like what it received; soft errors are not managed by the library but are reported as valid data responses, as described below.  A hard error is something that prevented the library from completing an operation and is reported directly to the caller.

All library functions report hard errors by returning ```nil, err_type, err_msg``` by default.  (This error handling can be overridden by providing a custom error handler at the module-, client- or call level, which is described later.)

```err_type``` and ```err_msg``` are strings.  ```err_type``` is one of the following values:
- 'SOCKET' -- an error occurred at the network level.
- 'PROTOCOL' -- the library didn't understand what the server said.
- 'USAGE' -- there was a problem with how you called a function, perhaps invalid arguments.

'SOCKET' and 'PROTOCOL' errors are generally unrecoverable and require you to close and re-establish the connection to the server.

### Custom Error Handlers

Custom error handler functions can be provided at various points in the library to override default behaviour.  An error handler is called with two arguments ```err_type``` and ```err_msg``` as described above.  All return values of the error handler are passed back to the original caller, assuming the error handler returns at all.  Examples:
```lua
-- an error handler that raises a Lua error.
function my_error_handler(err_type, err_msg)
  error(err_type .. ' ' .. err_msg)
end

-- an error handler that formats the error as a single string
function my_special_handler(err_type, err_msg)
  return nil, err_type .. ' ' .. err_msg
end
```

### Response Handling
All redis commands return a value that is of one of the following types:
- STATUS
- ERROR
- INT
- STRING
- ARRAY

STRING and ARRAY types may be nil, empty or appropriate content.  Arrays are integer keyed tables containing elements of the above types and may contain other arrays.  Data responses are by default formatted as a table (This can be overridden by providing a custom response renderer, described later):
```lua
{
  type = redis_client.response.STATUS, -- .ERROR, .INT, .STRING or .ARRAY
  data = data,
}
```
Some example responses:
```lua
-- PING =
{
  type = redis_client.response.STATUS,
  data = 'PONG',
}

-- GET string =
{
  type = redis_client.response.STRING,
  data = 'string value',
}

-- LRANGE list 0 -1 =
{
  type = redis_client.response.ARRAY,
  data = {
    {
      type = redis_client.response.STRING,
      data = 'list entry 1',
    },
    {
      type = redis_client.response.STRING,
      data = 'list entry 2',
    },
  },
}
```

## redis-client.protocol

This module is responsible for encoding/decoding messages on the wire.

### redis-client.protocol.send\_command
```lua
ok, err_type, err_msg = redis_client.protocol.send_command(file, args)
```
```file```: an object that behaves like a Lua ```file``` object, providing ```read```, ```write``` and ```flush``` functions.

```args```: a array of strings/integers containing the redis command and arguments.

Returns ```true``` or ```nil, err_type, err_msg``` on failure.

Example:
```lua
ok, err_type, err_msg = redis_client.protocol.send_command(file, { 'get', 'string' })
```

### redis-client.protocol.read\_response
```lua
ok, err_type, err_msg = redis_client.protocol.read_response(file)
```
```file```: an object that behaves like a Lua ```file``` object, providing ```read```, ```write``` and ```flush``` functions.

Returns a table containing the response data (see [Response Handling](#response-handling) or ```nil, err_type, err_msg``` on failure.

## redis-client.response

This module provides the default response formatting for higher-level modules.  The default response rendering can be changed by replacing the ```redis-client.response.new``` function, for example:

```lua
redis_client.response.new = function(cmd, options, args, type, data)
  return {
    type = type,
    data = data
  }
end
```
```cmd```, ```options``` and ```args``` are the (uppercased) command, options and arguments that were given as part of the redis command.

```type``` and ```data``` are as described above in [Response Handling](#response-handling).

## redis-client.redis

This module provides low-level redis functionality, establishing a network connection and providing a client object that can be used to perform actions on a redis server.

### redis-client.redis.new
```lua
client, err_type, err_msg = redis_client.redis.new(socket, error_handler)
```
```socket```: a cqueues socket object that is connected to the redis server.

```error_handler```: (optional) the error handler function that should be used for this client by default, overriding the module default.  See [Custom Error Handlers](#custom-error-handlers).

Returns a client object or ```nil, err_type, err_msg``` on failure.

### redis-client.redis.connect
```lua
client, err_type, err_msg = redis_client.redis.connect(host, port, error_handler)
```
```host```: (optional, default: '127.0.0.1') a resolvable hostname or IP address that will be used to connect to the redis server.

```port```: (optional, default: 6379) the listening port of the redis server.

```error_handler```: (optional) the error handler function that should be used for this client by default, overriding the module default.  See [Custom Error Handlers](#custom-error-handlers).

Returns a client object or ```nil, err_type, err_msg``` on failure.

### redis-client.redis.error\_handler

The default error handler used by client objects.  See [Custom Error Handlers](#custom-error-handlers).

### client:call
```lua
response, err_type, err_msg = client:call(...)
```

```client:call``` expects two tables, the first containing options for the call and the second containing the redis command and arguments.  This function tries to be flexible; it can be called in many ways and it will try to do the right thing:
```lua
client:call('ping') -- client:call({}, {'ping'})
client:call('ping', {options}) -- client:call({options}, {'ping'})
client:call('get', 'string') -- client:call({}, {'get', 'string'})
client:call({options}, 'get', 'string') -- client:call({options}, {'get', 'string'})
client:call('get', {options}, 'string') -- client:call({options}, {'get', 'string'})
client:call('lrange', {options}, {0, -1}) -- client:call({options}, {'lrange', 0, -1})
```

```client:call``` will issue the request to the redis server and wait for a response.  On error it will call the appropriate error handler or return ```nil, err_type, err_msg``` to the caller.

```options.error_handler```: the error handler to be used for this call.
```options.response_renderer```: the response renderer to be used for this call.
```options.whitelist```: a table of allowable redis commands, e.g. ```{ 'GET', 'PING' }```.  If present, any commands not in this list will be rejected.
```options.blacklist```: a table of disallowed redis commands, e.g. ```{ 'GET', 'PING' }```.  If present, any commands in this list will be rejected.

### client:next\_publication
```lua
response, err_type, err_msg = client:next_publication(options)
```

```options.timeout```: The amount of time the function will wait before giving up.
```options.error_handler```: the error handler to be used for this call.
```options.response_renderer```: the response renderer to be used for this call.

```client:next_publication``` will wait for a publication to be received from the server.  If ```options.timeout``` is not given, it will wait indefinitely.  Errors will be handled as above.  On timeout, an empty redis array will be returned.

### client:close
```lua
client:close()
```

Closes the client and ends the server connection.

### client.error\_handler

The default error handler used for calls made using this client.  Initially set on creation, can be replaced at any time.

## redis-client

redis-client provides the highest level abstraction for redis commands, providing:
- intelligent transformation of responses based on the commands that produced them
- transaction management
- state-based command rejection

As a convenience, all sub-modules are made available within the redis-cient table, i.e.
```lua
redis-client.redis
redis-client.protocol
redis-client.response
```

### redis-client.new
```lua
client, err_type, err_msg = redis_client.new(redis_client, error_handler)
```
```redis_client```: a redis-client.redis client object. (See [redis-client.redis.connect](#redis-clientredisconnect) or [redis-client.redis.new](#redis-clientredisnew).)

```error_handler```: (optional) the error handler function that should be used for this client by default, overriding the module default.  See [Custom Error Handlers](#custom-error-handlers).

Returns a client object or ```nil, err_type, err_msg``` on failure.

### redis-client.connect
```lua
rc, err_type, err_msg = redis_client.connect(host, port, error_handler)
```
```host```: (optional, default: '127.0.0.1') a resolvable hostname or IP address that will be used to connect to the redis server.

```port```: (optional, default: 6379) the listening port of the redis server.

```error_handler```: (optional) the error handler function that should be used for this client by default, overriding the module default.  See [Custom Error Handlers](#custom-error-handlers).

Returns a client object or ```nil, err_type, err_msg``` on failure.

### redis-client.error\_handler

The default error handler used by client objects.  See [Custom Error Handlers](#custom-error-handlers).

### rc:<foo>

redis-client will transform any non-existing, string key ```foo``` into a redis call with command ```'foo'```.  i.e.
```lua
rc:get(...) -- becomes rc:call('get', ...)
```

### rc:call
```lua
response, err_type, err_msg = rc:call(...)
```

This has the same calling semantics as [redis-client.redis client:call()](#clientcall), but also accepts an additional ```option.callback```.  If a callback function is given, it will be called when the command response has been received, just before returning to the caller.  In the event of an error, ```options.callback``` will not be called.  Callbacks are called after response rendering has taken place.
```lua
response, err_type, err_msg = rc:call('get', {
    callback = function(cmd, options, args, response)
      -- in this example: callback('GET', {callback=...}, {'string'}, response)
    end
  }, 'string')
```

### rc:hmget, rc:hgetall
```lua
response, err_type, err_msg = rc:hmget(...)
response, err_type, err_msg = rc:hgetall(...)
```

These commands use ```rc:call``` to issue the appropriate command to the redis server, but transform the response from an indexed array of ```{'key', 'value', 'key', 'value', ...}``` into a table of key-value pairs: ```{ key = 'value', ...}```, for example:

```lua
response = rc:hmget('hash', 'key1', 'key2')
-- response == {
--   type = redis.response.ARRAY,
--   data = {
--     key1 = { type = redis.response.STRING, data = 'value1' },
--     key2 = { type = redis.response.STRING, data = 'value1' },
--   }
-- }
```

### rc:hmset
```lua
response, err_type, err_msg = rc:hmset({ key1 = 'value1', key2 = 'value2'})
```

This operates in exactly the same manner as ```rc:call()``` except that the arguments may include key-value pairs which are automatically transformed into indexed array elements.

### rc:close
```lua
rc:close()
```

Closes the client and ends the server connection.

### rc:multi
```lua
transaction = rc:multi()
```

Issues a MULTI command to the redis server and returns a transaction object which behaves in the same manner as ```rc```.  Any subsequent use of ```rc``` will block until the transaction is completed (e.g. by 'DISCARD', 'EXEC' or 'RESET')

### multi:<foo>

The calling semantics are identical to ```rc:<foo>```, however it should be noted that within a transaction, the redis response will be either a ```redis.response.ERROR``` or a ```redis.response.STATUS``` with data ```'QUEUED'```.

### multi:exec
```lua
response, err_type, err_msg = multi:exec()
```

This issues the EXEC call to the redis server to execute all queued commands.  All individual command renderers and callbacks will be called again with the actual response of the command.  Finally, any callback for the ```exec()``` command will be called.  The response for the ```exec()``` call is a redis array containing the responses of each queued command.  For example:
```lua
local options = {
  callback = function(cmd, options, args, response)
}

local multi = rc:multi()
multi:get('string', options)
-- options.callback('GET', options, {'string'}, { type = redis.response.STATUS, data = 'QUEUED' }) called

local response = multi:exec(options)
-- options.callback('GET', options, {'string'}, { type = redis.response.STRING, data = 'My string' }) called
-- options.callback('EXEC', options, {}, {
--   type = redis.response.ARRAY,
--   data = {
--     { type = redis.response.STRING, data = 'My string' },
--   }
-- }) called
--
-- response = {
--   type = redis.response.ARRAY,
--   data = {
--     { type = redis.response.STRING, data = 'My string' },
--   }
-- }
```

