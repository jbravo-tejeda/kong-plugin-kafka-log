local BasePlugin = require "kong.plugins.base_plugin"
local basic_serializer = require "kong.plugins.log-serializers.basic"
local producers = require "kong.plugins.verifi-kafka-log.producers"
local cjson = require "cjson"
local cjson_encode = cjson.encode
local cjson_decode = cjson.decode
local utils = require "kong.tools.utils"
local concat = table.concat
local ngx = ngx
local kong = kong
local gsub = string.gsub
local res_get_headers = ngx.resp.get_headers
local table_concat = table.concat
local KafkaLogHandler = BasePlugin:extend()

KafkaLogHandler.PRIORITY = 5
KafkaLogHandler.VERSION = "0.0.1"

local mt_cache = { __mode = "k" }
local producers_cache = setmetatable({}, mt_cache)
local plugin_uuid = utils.uuid()

--- Computes a cache key for a given configuration.
local function cache_key(conf)
  -- here we rely on validation logic in schema that automatically assigns a unique id
  -- on every configuartion update
--  return conf.uuid
  return plugin_uuid
end 

function KafkaLogHandler:new()
  KafkaLogHandler.super.new(self, "verifi-kafka-log")
end

function KafkaLogHandler:access(conf)
  KafkaLogHandler.super.access(self)

  ngx.ctx.rt_body_chunks = {}
  ngx.ctx.rt_body_chunk_number = 1
end

function KafkaLogHandler:body_filter(conf)
  KafkaLogHandler.super.body_filter(self)

  if conf.log_response_body then
  
    local cache_key = cache_key(conf)
    if not cache_key then
      ngx.log(ngx.ERR, "[verifi-kafka-log] cannot log a given request because configuration has no uuid")
      return
    end
  
    local producer = producers_cache[cache_key]
    if not producer then
      kong.log.notice("creating a new Kafka Producer for cache key: ", cache_key)
  
      local err
  
      producer, err = producers.new(conf)
  
      if not producer then
        ngx.log(ngx.ERR, "[verifi-kafka-log] failed to create a Kafka Producer for a given configuration: ", err)
        return
      end
  
      producers_cache[cache_key] = producer
  
    end
  
    local chunk, eof = ngx.arg[1], ngx.arg[2]
  
    if not eof then
      ngx.ctx.rt_body_chunks[ngx.ctx.rt_body_chunk_number] = chunk
      ngx.ctx.rt_body_chunk_number = ngx.ctx.rt_body_chunk_number + 1
--      ngx.arg[1] = nil
  
    else
      local body = table_concat(ngx.ctx.rt_body_chunks)
      local ok, err = producer:send(conf.topic, nil, cjson_encode(body))
--      ngx.arg[1] = body
    end
  end
end

--- Publishes a message to Kafka.
-- Must run in the context of `ngx.timer.at`.
local function log(premature, conf, message)
  if premature then
    return
  end

  local cache_key = cache_key(conf)

  if not cache_key then
    ngx.log(ngx.ERR, "[verifi-kafka-log] cannot log a given request because configuration has no uuid")
    return
  end

  local producer = producers_cache[cache_key]

  if not producer then
    kong.log.notice("creating a new Kafka Producer for cache key: ", cache_key)

    local err
    producer, err = producers.new(conf)
    if not producer then
      ngx.log(ngx.ERR, "[verifi-kafka-log] failed to create a Kafka Producer for a given configuration: ", err)
      return
    end

    producers_cache[cache_key] = producer
  end

  local ok, err = producer:send(conf.topic, nil, cjson_encode(message))
  if not ok then
    ngx.log(ngx.ERR, "[verifi-kafka-log] failed to send a message on topic ", conf.topic, ": ", err)
    return
  end
end

function KafkaLogHandler:log(conf, other)
  KafkaLogHandler.super.log(self)

  local message = basic_serializer.serialize(ngx)
  local ok, err = ngx.timer.at(0, log, conf, message)
  if not ok then
    ngx.log(ngx.ERR, "[verifi-kafka-log] failed to create timer: ", err)
  end
end

return KafkaLogHandler
