package = "redis-client"
version = "scm-0"

description = {
  summary = "Redis client library for Lua",
  homepage = "https://github.com/Oozlum/redis-client",
  license = "MIT/X11",
}

source = {
  url = "git+https://github.com/Oozlum/redis-client.git",
}

dependencies = {
  "lua >= 5.1",
  "cqueues >= 20150907",
}

build = {
  type = "builtin",
  modules = {
    ["redis-client.init"] = "redis-client/init.lua",
    ["redis-client.protocol"] = "redis-client/protocol.lua",
    ["redis-client.redis"] = "redis-client/redis.lua",
    ["redis-client.response"] = "redis-client/response.lua",
    ["redis-client.util"] = "redis-client/util.lua",
  },
}
