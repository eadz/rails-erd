class User
  def save
    UserService.persist(self)
  end

  def self.find(id)
    new
  end
end
