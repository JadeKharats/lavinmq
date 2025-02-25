module LavinMQ
  abstract class User
    alias Permissions = NamedTuple(config: Regex, read: Regex, write: Regex)
  end
end
