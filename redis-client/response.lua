-- Construction of a redis response object.

return {
  STATUS = 'STATUS',
  ERROR = 'ERROR',
  INT = 'INT',
  STRING = 'STRING',
  ARRAY = 'ARRAY',

  new = function(cmd, options, args, response_type, response_data)
    print(('%s renderer: %s %s'):format(cmd, response_type, tostring(response_data)))
    return {
      type = response_type,
      data = response_data
    }
  end
}
