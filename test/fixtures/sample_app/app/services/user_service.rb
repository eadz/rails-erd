class UserService
  def self.persist(user)
    true
  end

  def self.notify(user)
    UserMailer.welcome(user)
  end
end
