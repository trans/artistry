module Artistry
  # Base class for Artistry registry errors.
  class Error < Exception
  end

  # A declared code isn't one or two uppercase letters.
  class InvalidCode < Error
    getter code : String

    def initialize(@code : String)
      super("Invalid artifact code #{@code.inspect}: a code is one or two uppercase letters (A-Z)")
    end
  end

  # A kind declares a code that another kind already owns.
  class CodeConflict < Error
    getter code : String
    getter plugin : String
    getter kind : String
    getter owner_plugin : String
    getter owner_kind : String

    def initialize(@code : String, @plugin : String, @kind : String, @owner_plugin : String, @owner_kind : String)
      super("#{@plugin}/#{@kind} declares code #{@code}, but #{@code} already belongs to #{@owner_plugin}/#{@owner_kind}")
    end
  end

  # A kind is already registered under a different code than it now declares.
  class CodeMismatch < Error
    getter plugin : String
    getter kind : String
    getter registered_code : String
    getter declared_code : String

    def initialize(@plugin : String, @kind : String, @registered_code : String, @declared_code : String)
      super("#{@plugin}/#{@kind} declares code #{@declared_code}, but this database registered it as #{@registered_code}")
    end
  end
end
