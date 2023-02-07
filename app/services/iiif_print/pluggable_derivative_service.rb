# General derivative service for IiifPrint, which is meant to wrap
#   and replace the stock Hyrax::FileSetDerivativeService with a proxy
#   that runs one or more derivative service "plugin" components.
#
#   Note: Hyrax::DerivativeService consumes this, instead of (directly)
#   consuming Hyrax::FileSetDerivativeService.
#
#   Unlike the "run the first valid plugin" arrangement that the
#   Hyrax::DerivativeService uses to run an actual derivative creation
#   service component, this component is:
#
#   (a) Consumed by Hyrax::DerivativeService as that first valid plugin;
#
#   (b) Wraps and runs 0..* plugins, not just the first.
#
# This should be registered to take precedence over default by:
#   Hyrax::DerivativeService.services.unshift(
#     IiifPrint::PluggableDerivativeService
#   )
#
#   Modify IiifPrint::PluggableDerivativeService.plugins
#   to add, remove, or reorder plugin (derivative service) classes.
#
class IiifPrint::PluggableDerivativeService
  class_attribute :allowed_methods, default: [:cleanup_derivatives, :create_derivatives]
  class_attribute :default_plugins, default: [Hyrax::FileSetDerivativesService]
  class_attribute :derivative_path_factory, default: Hyrax::DerivativePath

  def initialize(file_set, plugins: plugins_for(file_set))
    @file_set = file_set
    @plugins = Array.wrap(plugins)
  end

  attr_reader :file_set, :plugins
  delegate :uri, :mime_type, to: :file_set

  # this wrapper/proxy/composite is always valid, but it may compose
  #   multiple plugins, some of which may or may not be valid, so
  #   validity checks happen within as well.
  def valid?
    true
  end

  def respond_to_missing?(method_name)
    allowed_methods.include?(method_name) || super
  end

  # get derivative services relevant to method name and file_set context
  #   -- omits plugins if particular destination exists or will soon.
  def services(method_name)
    result = plugins.map { |plugin| plugin.new(file_set) }.select(&:valid?)
    result.select do |plugin|
      dest = nil
      dest = plugin.class.target_extension if plugin.class.respond_to?(:target_extension)
      !skip_destination?(method_name, dest)
    end
  end

  def method_missing(name, *args, **opts, &block)
    if respond_to_missing?(name)
      # we have an allowed method, construct services and include all valid
      #   services for the file_set
      # services = plugins.map { |plugin| plugin.new(file_set) }.select(&:valid?)
      # run all valid services, in order:
      services(name).each do |plugin|
        plugin.send(name, *args)
      end
    else
      super
    end
  end

  private

  def skip_destination?(method_name, destination_name)
    return false if file_set.id.nil? || destination_name.nil?
    return false unless method_name == :create_derivatives
    # skip :create_derivatives if existing --> do not re-create
    existing_derivative?(destination_name) ||
      impending_derivative?(destination_name)
  end

  def existing_derivative?(name)
    path = derivative_path_factory.derivative_path_for_reference(
      file_set,
      name
    )
    File.exist?(path)
  end

  # is there an impending attachment from ingest logged to db?
  #   -- avoids stomping over pre-made derivative
  #      for which an attachment is still in-progress.
  def impending_derivative?(name)
    IiifPrint::DerivativeAttachment.exists?(
      fileset_id: file_set.id,
      destination_name: name
    )
  end

  def plugins_for(file_set)
    return Array(default_plugins) unless file_set.parent.try(:iiif_print_config?)

    (file_set.parent.iiif_print_config.derivative_service_plugins + Array(default_plugins)).flatten.compact.uniq
  end
end
