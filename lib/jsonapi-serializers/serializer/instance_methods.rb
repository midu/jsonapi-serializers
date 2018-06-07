module JSONAPI
  module Serializer
    module InstanceMethods
      @@class_names = {}
      @@formatted_attribute_names = {}
      @@unformatted_attribute_names = {}

      attr_accessor :object
      attr_accessor :context
      attr_accessor :base_url

      def initialize(object, options = {})
        @object = object
        @options = options
        @context = options[:context] || {}
        @base_url = options[:base_url]

        # Internal serializer options, not exposed through attr_accessor. No touchie.
        @_fields = options[:fields] || {}
        @_include_linkages = options[:include_linkages] || []
      end

      # Override this to customize the JSON:API "id" for this object.
      # Always return a string from this method to conform with the JSON:API spec.
      def id
        object.id.to_s
      end

      # Override this to customize the JSON:API "type" for this object.
      # By default, the type is the object's class name lowercased, pluralized, and dasherized,
      # per the spec naming recommendations: http://jsonapi.org/recommendations/#naming
      # For example, 'MyApp::LongCommment' will become the 'long-comments' type.
      def type
        class_name = object.class.name
        @@class_names[class_name] ||= JSONAPI::Serializer.transform_key_casing(class_name.demodulize.tableize).freeze
      end

      # Override this to customize how attribute names are formatted.
      # By default, attribute names are dasherized per the spec naming recommendations:
      # http://jsonapi.org/recommendations/#naming
      def format_name(attribute_name)
        attr_name = attribute_name.to_s
        @@formatted_attribute_names[attr_name] ||= JSONAPI::Serializer.transform_key_casing(attr_name).freeze
      end

      # The opposite of format_name. Override this if you override format_name.
      def unformat_name(attribute_name)
        attr_name = attribute_name.to_s
        @@unformatted_attribute_names[attr_name] ||= attr_name.underscore.freeze
      end

      # Override this to provide resource-object jsonapi object containing the version in use.
      # http://jsonapi.org/format/#document-jsonapi-object
      def jsonapi; end

      # Override this to provide resource-object metadata.
      # http://jsonapi.org/format/#document-structure-resource-objects
      def meta; end

      # Override this to set a base URL (http://example.com) for all links. No trailing slash.
      def base_url
        @base_url
      end

      def self_link
        "#{base_url}/#{type}/#{id}"
      end

      def relationship_self_link(attribute_name)
        "#{self_link}/relationships/#{format_name(attribute_name)}"
      end

      def relationship_related_link(attribute_name)
        "#{self_link}/#{format_name(attribute_name)}"
      end

      def links
        data = {}
        data['self'] = self_link if self_link
        data
      end

      def relationships
        data = {}
        # Merge in data for has_one relationships.
        has_one_relationships.each do |attribute_name, attr_data|
          formatted_attribute_name = format_name(attribute_name)
          result = {}

          options = attr_data[:options]
          if options[:include_links]
            links_self = relationship_self_link(attribute_name)
            links_related = relationship_related_link(attribute_name)

            result['links'] = {
              'self' => (links_self if links_self),
              'related' => (links_related if links_related)
            }
          end

          next unless @_include_linkages.include?(formatted_attribute_name) || options[:include_data]
          object = has_one_relationship(attribute_name, attr_data)
          if object.nil?
            # Spec: Resource linkage MUST be represented as one of the following:
            # - null for empty to-one relationships.
            # http://jsonapi.org/format/#document-structure-resource-relationships
            result['data'] = nil
          else
            related_object_serializer = JSONAPI::Serializer.find_serializer(object, options)
            result['data'] = {
              'id' => related_object_serializer.id,
              'type' => related_object_serializer.type
            }
          end
          data[formatted_attribute_name] = result
        end

        # Merge in data for has_many relationships.
        has_many_relationships.each do |attribute_name, attr_data|
          formatted_attribute_name = format_name(attribute_name)
          result = {}

          options = attr_data[:options]
          if options[:include_links]
            links_self = relationship_self_link(attribute_name)
            links_related = relationship_related_link(attribute_name)
            result['links'] = {
              'self' => (links_self if links_self),
              'related' => (links_related if links_related)
            }
          end

          # Spec: Resource linkage MUST be represented as one of the following:
          # - an empty array ([]) for empty to-many relationships.
          # - an array of linkage objects for non-empty to-many relationships.
          # http://jsonapi.org/format/#document-structure-resource-relationships
          next unless @_include_linkages.include?(formatted_attribute_name) || options[:include_data]
          result['data'] = []
          objects = has_many_relationship(attribute_name, attr_data) || []
          objects.each do |obj|
            related_object_serializer = JSONAPI::Serializer.find_serializer(obj, options)
            related_object_data = {
              'id' => related_object_serializer.id,
              'type' => related_object_serializer.type
            }
            related_object_data['meta'] = related_object_serializer.meta if related_object_serializer.meta
            result['data'] << related_object_data
          end
          data[formatted_attribute_name] = result
        end
        data
      end

      def attributes
        attributes_map = self.class.attributes_map
        return {} if attributes_map.nil?
        attributes = {}
        attributes_map.each do |attribute_name, attr_data|
          next unless should_include_attr?(attribute_name)
          value = evaluate_attr_or_block(attribute_name, attr_data[:attr_or_block])
          attributes[format_name(attribute_name)] = value
        end
        attributes
      end

      def has_one_relationships
        to_one_associations = self.class.to_one_associations
        return {} if to_one_associations.nil?
        data = {}
        to_one_associations.each do |attribute_name, attr_data|
          next unless should_include_attr?(attribute_name)
          data[attribute_name] = attr_data
        end
        data
      end

      def has_one_relationship(attribute_name, attr_data)
        evaluate_attr_or_block(attribute_name, attr_data[:attr_or_block])
      end

      def has_many_relationships
        to_many_associations = self.class.to_many_associations
        return {} if to_many_associations.nil?
        data = {}
        to_many_associations.each do |attribute_name, attr_data|
          next unless should_include_attr?(attribute_name)
          data[attribute_name] = attr_data
        end
        data
      end

      def has_many_relationship(attribute_name, attr_data)
        evaluate_attr_or_block(attribute_name, attr_data[:attr_or_block])
      end

      protected

      def should_include_attr?(attribute_name)
        show_attr = true
        fields = @_fields[type]
        show_attr &&= fields.include?(format_name(attribute_name).to_sym) if fields
        show_attr
      end

      def evaluate_attr_or_block(_attribute_name, attr_or_block)
        if attr_or_block.is_a?(Proc)
          # A custom block was given, call it to get the value.
          instance_eval(&attr_or_block)
        else
          # Default behavior, call a method by the name of the attribute.
          object.send(attr_or_block)
        end
      end
    end
  end
end
