require "json"
require "jargon"

module Artistry
  class ValidationError < Exception
    getter errors : Array(FieldError)

    record FieldError, field : String, message : String

    def initialize(@errors)
      super(format_message)
    end

    private def format_message : String
      errors.map { |e| "#{e.field}: #{e.message}" }.join("; ")
    end
  end

  module Validator
    # Validate data against a JSON Schema.
    # Raises ValidationError if validation fails.
    def self.validate(data : JSON::Any, schema : JSON::Any) : Nil
      jargon_schema = Jargon::Schema.from_json_any(schema)
      data_hash = data.as_h? || {} of String => JSON::Any
      string_errors = Jargon::Validator.validate(data_hash, jargon_schema)

      unless string_errors.empty?
        field_errors = string_errors.map { |msg| parse_error(msg) }
        raise ValidationError.new(field_errors)
      end
    end

    # Apply default values from schema to data. Returns new JSON::Any with defaults filled in.
    def self.apply_defaults(data : JSON::Any, schema : JSON::Any) : JSON::Any
      jargon_schema = Jargon::Schema.from_json_any(schema)
      root = jargon_schema.root
      apply_property_defaults(data, root)
    end

    private def self.apply_property_defaults(data : JSON::Any, prop : Jargon::Property) : JSON::Any
      props = prop.properties
      return data unless props

      obj = data.as_h?
      return data unless obj

      result = obj.dup
      props.each do |key, child_prop|
        if result.has_key?(key)
          # Recurse into existing nested objects
          if child_prop.properties
            result[key] = apply_property_defaults(result[key], child_prop)
          end
        else
          # Apply default if present
          if default_val = child_prop.default
            result[key] = default_val
          end
        end
      end

      JSON::Any.new(result)
    end

    # Parse a Jargon error string into a FieldError.
    private def self.parse_error(msg : String) : ValidationError::FieldError
      # Jargon error formats:
      #   "Missing required field: name"
      #   "Invalid type for name: expected string, got Int64"
      #   "Value for name must be >= 1"
      #   "Invalid value for name: must be one of a, b"
      #   "name must have at least 1 items"
      #   "Unknown property 'name': additionalProperties is false"
      case msg
      when /^Missing required field: (.+)$/
        ValidationError::FieldError.new($1, "required field missing")
      when /^Invalid type for (.+?): expected (.+?), got (.+)$/
        ValidationError::FieldError.new($1, "expected #{$2}, got #{$3}")
      when /^Value for (.+?) must be (.+)$/
        ValidationError::FieldError.new($1, "must be #{$2}")
      when /^Invalid value for (.+?): must be one of (.+)$/
        ValidationError::FieldError.new($1, "must be one of #{$2}")
      when /^(.+?) must have (.+)$/
        ValidationError::FieldError.new($1, "must have #{$2}")
      when /^Unknown property '(.+?)': (.+)$/
        ValidationError::FieldError.new($1, $2)
      else
        ValidationError::FieldError.new("(unknown)", msg)
      end
    end
  end
end
