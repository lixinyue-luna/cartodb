# coding: UTF-8

require 'securerandom'
require_dependency 'google_plus_api'
require_dependency 'carto/strong_password_validator'
require_dependency 'dummy_password_generator'

# This class is quite coupled to UserCreation.
module CartoDB
  class UserAccountCreator
    include DummyPasswordGenerator

    PARAM_USERNAME = :username
    PARAM_EMAIL = :email
    PARAM_PASSWORD = :password

    # For user creations from orgs
    PARAM_SOFT_GEOCODING_LIMIT = :soft_geocoding_limit
    PARAM_SOFT_HERE_ISOLINES_LIMIT = :soft_here_isolines_limit
    PARAM_SOFT_OBS_SNAPSHOT_LIMIT = :soft_obs_snapshot_limit
    PARAM_SOFT_OBS_GENERAL_LIMIT = :soft_obs_general_limit
    PARAM_SOFT_TWITTER_DATASOURCE_LIMIT = :soft_twitter_datasource_limit
    PARAM_SOFT_MAPZEN_ROUTING_LIMIT = :soft_mapzen_routing_limit
    PARAM_QUOTA_IN_BYTES = :quota_in_bytes
    PARAM_VIEWER = :viewer

    def initialize(created_via)
      @built = false
      @organization = nil
      @google_user_data = nil
      @user = ::User.new
      @user_params = {}
      @custom_errors = {}
      @created_via = created_via
    end

    def with_username(value)
      with_param(PARAM_USERNAME, value)
    end

    def with_email(value)
      with_param(PARAM_EMAIL, value)
    end

    def with_password(value)
      with_param(PARAM_PASSWORD, value)
    end

    def with_soft_geocoding_limit(value)
      with_param(PARAM_SOFT_GEOCODING_LIMIT, value)
    end

    def with_soft_here_isolines_limit(value)
      with_param(PARAM_SOFT_HERE_ISOLINES_LIMIT, value)
    end

    def with_soft_obs_snapshot_limit(value)
      with_param(PARAM_SOFT_OBS_SNAPSHOT_LIMIT, value)
    end

    def with_soft_obs_general_limit(value)
      with_param(PARAM_SOFT_OBS_GENERAL_LIMIT, value)
    end

    def with_soft_twitter_datasource_limit(value)
      with_param(PARAM_SOFT_TWITTER_DATASOURCE_LIMIT, value)
    end

    def with_soft_mapzen_routing_limit(value)
      with_param(PARAM_SOFT_MAPZEN_ROUTING_LIMIT, value)
    end

    def with_quota_in_bytes(value)
      with_param(PARAM_QUOTA_IN_BYTES, value)
    end

    def with_viewer(value)
      with_param(PARAM_VIEWER, value)
    end

    def with_organization(organization)
      @built = false
      @organization = organization
      @user = ::User.new_with_organization(organization)
      self
    end

    def with_invitation_token(invitation_token)
      @invitation_token = invitation_token
      self
    end

    def with_email_only(email)
      with_email(email)
      with_username(email.split('@')[0])
      with_password(SecureRandom.hex)
      self
    end

    def user
      @user
    end

    def with_google_token(google_access_token)
      @built = false
      # get_user_data can return nil
      @google_user_data = GooglePlusAPI.new.get_user_data(google_access_token)
      self
    end

    def with_github_oauth_api(github_api)
      @built = false
      @github_api = github_api
      self
    end

    def valid?
      build

      if @organization
        if @organization.owner.nil?
          if !promote_to_organization_owner?
            @custom_errors[:organization] = ["Organization owner is not set. Administrator must login first."]
          end
        else
          validate_organization_soft_limits
        end

        if @organization.strong_passwords_enabled && @created_via != Carto::UserCreation::CREATED_VIA_LDAP
          password_validator = Carto::StrongPasswordValidator.new
          password_errors = password_validator.validate(@user.password)

          unless password_errors.empty?
            @custom_errors[:password] = [password_validator.formatted_error_message(password_errors)]
          end
        end
      end

      @user.valid? && @user.validate_credentials_not_taken_in_central && @custom_errors.empty?
    end

    def validation_errors
      @user.errors.merge!(@custom_errors)
    end

    def enqueue_creation(current_controller)
      user_creation = build_user_creation

      user_creation.save

      common_data_url = CartoDB::Visualization::CommonDataService.build_url(current_controller)
      ::Resque.enqueue(::Resque::UserJobs::Signup::NewUser,
                       user_creation.id,
                       common_data_url,
                       promote_to_organization_owner?)

      { id: user_creation.id, username: user_creation.username }
    end

    def build_user_creation
      build

      Carto::UserCreation.new_user_signup(@user, @created_via).with_invitation_token(@invitation_token)
    end

    def build
      return if @built

      if @google_user_data
        @google_user_data.set_values(@user)
      elsif @github_api
        @user.github_user_id = @github_api.id
        @user.username = @github_api.username
        @user.email = @user_params[PARAM_EMAIL] || @github_api.email
        dummy_password = generate_dummy_password
        @user.password = dummy_password
        @user.password_confirmation = dummy_password
      else
        @user.email = @user_params[PARAM_EMAIL]
        @user.password = @user_params[PARAM_PASSWORD]
        @user.password_confirmation = @user_params[PARAM_PASSWORD]
      end

      @user.invitation_token = @invitation_token

      @user.username = @user_params[PARAM_USERNAME] if @user_params[PARAM_USERNAME]
      @user.soft_geocoding_limit = @user_params[PARAM_SOFT_GEOCODING_LIMIT] == 'true'
      @user.soft_here_isolines_limit = @user_params[PARAM_SOFT_HERE_ISOLINES_LIMIT] == 'true'
      @user.soft_obs_snapshot_limit = @user_params[PARAM_SOFT_OBS_SNAPSHOT_LIMIT] == 'true'
      @user.soft_obs_general_limit = @user_params[PARAM_SOFT_OBS_GENERAL_LIMIT] == 'true'
      @user.soft_twitter_datasource_limit = @user_params[PARAM_SOFT_TWITTER_DATASOURCE_LIMIT] == 'true'
      @user.soft_mapzen_routing_limit = @user_params[PARAM_SOFT_MAPZEN_ROUTING_LIMIT] == 'true'
      @user.quota_in_bytes = @user_params[PARAM_QUOTA_IN_BYTES] if @user_params[PARAM_QUOTA_IN_BYTES]
      @user.viewer = @user_params[PARAM_VIEWER] if @user_params[PARAM_VIEWER]

      @built = true
      @user
    end

    private

    # This is coupled to OrganizationUserController soft limits validations.
    def validate_organization_soft_limits
      owner = @organization.owner
      if @user_params[PARAM_SOFT_GEOCODING_LIMIT] == 'true' && !owner.soft_geocoding_limit
        @custom_errors[:soft_geocoding_limit] = ["Owner can't assign soft geocoding limit"]
      end
      if @user_params[PARAM_SOFT_HERE_ISOLINES_LIMIT] == 'true' && !owner.soft_here_isolines_limit
        @custom_errors[:soft_here_isolines_limit] = ["Owner can't assign soft here isolines limit"]
      end
      if @user_params[PARAM_SOFT_OBS_SNAPSHOT_LIMIT] == 'true' && !owner.soft_obs_snapshot_limit
        @custom_errors[:soft_obs_snapshot_limit] = ["Owner can't assign soft data observatory snapshot limit"]
      end
      if @user_params[PARAM_SOFT_OBS_GENERAL_LIMIT] == 'true' && !owner.soft_obs_general_limit
        @custom_errors[:soft_obs_general_limit] = ["Owner can't assign soft data observatory general limit"]
      end
      if @user_params[PARAM_SOFT_TWITTER_DATASOURCE_LIMIT] == 'true' && !owner.soft_twitter_datasource_limit
        @custom_errors[:soft_twitter_datasource_limit] = ["Owner can't assign soft twitter datasource limit"]
      end
      if @user_params[PARAM_SOFT_MAPZEN_ROUTING_LIMIT] == 'true' && !owner.soft_mapzen_routing_limit
        @custom_errors[:soft_mapzen_routing_limit] = ["Owner can't assign soft mapzen routing limit"]
      end
    end

    def with_param(key, value)
      @built = false
      @user_params[key] = value
      self
    end

    def promote_to_organization_owner?
      # INFO: Custom installs convention: org owner always has `<orgname>-admin` format
      !!(@organization && !@organization.owner_id && @user_params[PARAM_USERNAME] &&
        @user_params[PARAM_USERNAME] == "#{@organization.name}-admin")
    end
  end
end
