require "json"
require "./sortable_json"
require "./tag"

module LavinMQ
  abstract class User
    include SortableJSON
    alias Permissions = NamedTuple(config: Regex, read: Regex, write: Regex)
  end
end
