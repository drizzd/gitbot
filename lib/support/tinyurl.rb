class TinyURL

  def self.tiny(url)
    return nil unless url
    http = Net::HTTP.start("tinyurl.com", 80)
    begin
      response = http.post("/create.php", "url=#{url}")
    rescue Exception => e
      return url
    end

    if response.code == "200"
      begin
        body = response.read_body
        line = body.split("\n").find { |l| l =~ /^copy\('/ }
        i1 = line.index("http")
        i2 = line.rindex("\'")
        return line[i1...i2]
      rescue Exception => e
        return url
      end
    end
  end

end