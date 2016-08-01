module DoorkeeperAuth
  def self.included(base)
    base.extend ClassMethods

    base.class_attribute :api_accessible
    base.before_action :access_denied?

    def access_denied?
      raise "This resource is not accessible via the API" if disallowed?
    end

    def api_route?
      request.fullpath.include?("/api/")
    end

    def disallowed?
      !self.api_accessible
    end
  end

  module ClassMethods
    def api_accessible!(setting)
      self.api_accessible = setting
    end
  end
end