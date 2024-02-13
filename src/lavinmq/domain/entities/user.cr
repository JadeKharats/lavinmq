module LavinMQ::Domain::Entities
  enum Tag
    Administrator
    Monitoring
    Management
    PolicyMaker
    Impersonator
  end

  struct Permissions
    property config : Regex
    property read : Regex
    property write : Regex

    def initialize(@config, @read, @write)
    end
  end

  abstract class Password
    abstract def hash_algorithm : String
  end

  class User
    getter name : String
    getter password : Password? = nil
    getter permissions : Hash(String, Permissions) = Hash(String, Permissions).new
    property tags : Array(Tag) = Array(Tag).new
    property plain_text_password : String?

    def initialize(@name, @password, @tags)
    end
  end
end
