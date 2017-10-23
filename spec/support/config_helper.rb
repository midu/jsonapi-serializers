module ConfigHelper
  def config
    JSONAPI::Serializer.config
  end

  def with_config(hash)
    reset_class_variables

    old_config = config.dup
    JSONAPI::Serializer.config.update(hash)
    yield
  ensure
    JSONAPI::Serializer.config.replace(old_config)
    reset_class_variables
  end

  private

  def reset_class_variables
    JSONAPI::Serializer::InstanceMethods.class_variable_set(:@@class_names, {})
    JSONAPI::Serializer::InstanceMethods.class_variable_set(:@@formatted_attribute_names, {})
    JSONAPI::Serializer::InstanceMethods.class_variable_set(:@@unformatted_attribute_names, {})
  end
end
