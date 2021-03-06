class User < ApplicationRecord
  # for badges/medals using the merit gems
  include Merit
  has_merit

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable, :recoverable, :rememberable,
         :trackable, :validatable, :omniauthable, omniauth_providers: [:facebook],
         authentication_keys: [:mobile_number]
  has_many :loans, dependent: :destroy
  has_many :notifications, dependent: :destroy

  geocoded_by :city
  after_validation :geocode, if: :city_changed?

  phony_normalize :mobile_number, default_country_code: 'ZA'
  validates :mobile_number, presence: true, uniqueness: true, phony_plausible: true

  [:title, :first_name, :last_name, :address, :city, :postcode, :employment, :date_of_birth].each do |meth|
    validates meth, presence: true, on: :update, unless: -> user { user.updating_password? || user.updating_medals? }
  end

  validates :email, presence: { message: 'Email can only be edited - not deleted' },
            if: -> {email_was.present?},
            on: :update
  validate :photo_id, :id_present?,
            on: :update, unless: -> user { user.updating_password? || user.updating_medals? }

  def updating_password?
    @password_confirmation.present?
  end

  def updating_medals?
    sash_id_changed?
  end

  def email_required?
    false
  end

  def self.send_reset_password_instructions(attributes={})
    recoverable = find_or_initialize_with_errors(reset_password_keys, attributes, :not_found)
    if recoverable.persisted?
      if recoverable.email.present?
        recoverable.send_reset_password_instructions
      else
        link = Rails.application.routes.url_helpers.edit_user_password_url(
          ActionMailer::Base.default_url_options.merge(
            reset_password_token: recoverable.send(:set_reset_password_token)
          )
        )

        SmsJob.perform_later(
          recoverable.mobile_number,
          "Stride Password Reset: #{link}"
        )
      end
    end
    recoverable
  end

  mount_uploader :photo_id, PhotoUploader
  def self.find_for_facebook_oauth(auth)
    user_params = auth.to_h.slice(:provider, :uid)
    user_params.merge! auth.info.slice(:email, :first_name, :last_name)
    user_params[:token] = auth.credentials.token
    user_params[:token_expiry] = Time.at(auth.credentials.expires_at)

    user = User.where(provider: auth.provider, uid: auth.uid).first
    user ||= User.where(email: auth.info.email).first # User did a regular sign up in the past.
    if user
      user.update(user_params)
    else
      user = User.new(user_params)
      user.password = Devise.friendly_token[0,20]  # Fake password for validation
      user.save
    end

    return user
  end

  def self.find_first_by_auth_conditions(warden_conditions)
    conditions = warden_conditions.dup
    if email = conditions.delete(:email)
      where((email.include?('@') ? :email : :mobile_number) => email).first
    else
      super
    end
  end

  def full_name
    (first_name + ' ' + last_name).titleize
  end

  def update_with_facebook(auth)
    user_params = auth.to_h.slice(:provider, :uid)
    user_params.merge! auth.info.slice(:email, :first_name, :last_name)
    # :user_birthday, :user_location, :gender, :age_range, :user_education_history, :user_relationship',
    # user_params[:facebook_picture_url] = auth.info.image
    user_params[:token] = auth.credentials.token
    user_params[:token_expiry] = Time.at(auth.credentials.expires_at)
    self.update(user_params)
    return user_params
  end

  def check_facial_recognition
    Indico.api_key = ENV['INDICO_API_KEY']
    if photo_id.file.present?
      result = Indico.facial_localization(photo_id.file.file, {sensitivity: 0.4})
      if result.blank?
        errors.add(:photo_id, :no_face_recognised, message: "Face recognition failed. Please upload a valid photo ID")
      end
    end
  end

  private

  def id_present?
    if photo_id.present? || photo_id.metadata.present?
      check_facial_recognition if photo_id_changed?
      return
    end
  end
end
