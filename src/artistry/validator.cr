require "json"

module Artistry
  class ValidationError < Exception
    getter errors : Array(FieldError)

    record FieldError, field : String, message : String, expected : String? = nil, actual : String? = nil

    def initialize(@errors)
      super(format_message)
    end

    private def format_message : String
      errors.map { |e| "#{e.field}: #{e.message}" }.join("; ")
    end
  end

  module Validator
    TYPE_VALIDATORS = {
      "string"  => ->(v : JSON::Any) { !v.as_s?.nil? },
      "integer" => ->(v : JSON::Any) { !v.as_i64?.nil? },
      "float"   => ->(v : JSON::Any) { !v.as_f?.nil? },
      "number"  => ->(v : JSON::Any) { !v.as_i64?.nil? || !v.as_f?.nil? },
      "boolean" => ->(v : JSON::Any) { !v.as_bool?.nil? },
      "array"   => ->(v : JSON::Any) { !v.as_a?.nil? },
      "object"  => ->(v : JSON::Any) { !v.as_h?.nil? },
      "any"     => ->(v : JSON::Any) { true },
    }

    def self.validate(data : JSON::Any, schema : JSON::Any, strict : Bool = true) : Nil
      errors = [] of ValidationError::FieldError

      data_hash = data.as_h? || {} of String => JSON::Any
      schema_hash = schema.as_h? || {} of String => JSON::Any

      # Check each schema field
      schema_hash.each do |field, type_spec|
        type_str = type_spec.as_s? || "any"

        value = data_hash[field]?

        # Check if field is missing
        if value.nil?
          errors << ValidationError::FieldError.new(field, "required field is missing")
          next
        end

        # Check if value is null
        if value.raw.nil?
          errors << ValidationError::FieldError.new(field, "field cannot be null")
          next
        end

        # Type check
        validator = TYPE_VALIDATORS[type_str]?
        unless validator
          errors << ValidationError::FieldError.new(field, "unknown type '#{type_str}' in schema")
          next
        end

        unless validator.call(value)
          errors << ValidationError::FieldError.new(
            field, "expected #{type_str}, got #{json_type_name(value)}",
            type_str, json_type_name(value)
          )
        end
      end

      # Strict mode: check for unknown fields
      if strict
        schema_keys = schema_hash.keys.to_set
        data_hash.each_key do |field|
          unless schema_keys.includes?(field)
            errors << ValidationError::FieldError.new(field, "unknown field")
          end
        end
      end

      raise ValidationError.new(errors) unless errors.empty?
    end

    private def self.json_type_name(value : JSON::Any) : String
      case value.raw
      when String  then "string"
      when Int64   then "integer"
      when Float64 then "float"
      when Bool    then "boolean"
      when Array   then "array"
      when Hash    then "object"
      when Nil     then "null"
      else              "unknown"
      end
    end
  end
end
