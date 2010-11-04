#   Mad Mimi for Ruby

#   License

#   Copyright (c) 2010 Mad Mimi (nicholas@madmimi.com)

#   Permission is hereby granted, free of charge, to any person obtaining a copy
#   of this software and associated documentation files (the "Software"), to deal
#   in the Software without restriction, including without limitation the rights
#   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#   copies of the Software, and to permit persons to whom the Software is
#   furnished to do so, subject to the following conditions:

#   The above copyright notice and this permission notice shall be included in
#   all copies or substantial portions of the Software.

#   Except as contained in this notice, the name(s) of the above copyright holder(s) 
#   shall not be used in advertising or otherwise to promote the sale, use or other
#   dealings in this Software without prior written authorization.

#   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#   THE SOFTWARE.

require 'uri'
require 'net/http'
require 'net/https'
require 'crack'
require 'csv'

class MadMimi

  class MadMimiError < StandardError; end

  BASE_URL = 'api.madmimi.com'
  NEW_LISTS_PATH = '/audience_lists'
  AUDIENCE_MEMBERS_PATH = '/audience_members'
  AUDIENCE_LISTS_PATH = '/audience_lists/lists.xml'
  MEMBERSHIPS_PATH = '/audience_members/%email%/lists.xml'
  SUPPRESSED_SINCE_PATH = '/audience_members/suppressed_since/%timestamp%.txt'
  SUPPRESS_USER_PATH = ' /audience_members/%email%/suppress_email'
  PROMOTIONS_PATH = '/promotions.xml'
  MAILING_STATS_PATH = '/promotions/%promotion_id%/mailings/%mailing_id%.xml'
  SEARCH_PATH = '/audience_members/search.xml'
  MAILER_PATH = '/mailer'
  MAILER_TO_LIST_PATH = '/mailer/to_list'
  
  attr_reader :response

  def initialize(username, api_key, options = {})
    @api_settings = options.merge({ :username => username, :api_key => api_key })
  end
  
  def raise_exceptions
    options[:raise_exceptions]
  end

  def username
    @api_settings[:username]
  end

  def api_key
    @api_settings[:api_key]
  end

  def default_opt
    { :username => username, :api_key => api_key }
  end

  def lists
    request = do_request(AUDIENCE_LISTS_PATH, :get)
    Crack::XML.parse(request)
  end

  def memberships(email)
    request = do_request(MEMBERSHIPS_PATH.gsub('%email%', email), :get)
    Crack::XML.parse(request)
  end

  def new_list(list_name)
    do_request(NEW_LISTS_PATH, :post, :name => list_name)
  end

  def delete_list(list_name)
    do_request("#{NEW_LISTS_PATH}/#{URI.escape(list_name)}", :post, :'_method' => 'delete')
  end

  def csv_import(csv_string)
    do_request(AUDIENCE_MEMBERS_PATH, :post, :csv_file => csv_string)
  end

  def add_user(options)
    csv_data = build_csv(options)
    do_request(AUDIENCE_MEMBERS_PATH, :post, :csv_file => csv_data)
  end

  def add_to_list(email, list_name)
    do_request("#{NEW_LISTS_PATH}/#{URI.escape(list_name)}/add", :post, :email => email)
  end

  def remove_from_list(email, list_name)
    do_request("#{NEW_LISTS_PATH}/#{URI.escape(list_name)}/remove", :post, :email => email)
  end

  def suppressed_since(timestamp)
    do_request(SUPPRESSED_SINCE_PATH.gsub('%timestamp%', timestamp), :get)
  end
  
  def suppress_email(email)
    do_request(SUPPRESS_USER_PATH.gsub('%email%', email), :post)
  end

  def promotions
    request = do_request(PROMOTIONS_PATH, :get)
    Crack::XML.parse(request)
  end

  def mailing_stats(promotion_id, mailing_id)
    path = MAILING_STATS_PATH.gsub('%promotion_id%', promotion_id).gsub('%mailing_id%', mailing_id)
    request = do_request(path, :get)
    Crack::XML.parse(request)
  end

  def audience_search(query_string, raw = false)
    request = do_request(SEARCH_PATH, :get, :raw => raw, :query => query_string)
    Crack::XML.parse(request)
  end

  def send_mail(opt, yaml_body)
    options = opt.dup
    options[:body] = yaml_body.to_yaml
    if !options[:list_name].nil?
      do_request(MAILER_TO_LIST_PATH, :post, options, true)
    else
      do_request(MAILER_PATH, :post, options, true)
    end
  end
  
  # Not the most elegant, but it works for now. :)
  def add_users_to_list(list_name, arr)
    arr.each do |a|
      a[:add_list] = list_name
      add_user(a)
    end
  end

  def send_html(opt, html)
    options = opt.dup
    if html.include?('[[tracking_beacon]]') || html.include?('[[peek_image]]')
      options[:raw_html] = html
      if !options[:list_name].nil?
        unless html.include?('[[unsubscribe]]') || html.include?('[[opt_out]]')
          raise MadMimiError, "When specifying list_name, include the [[unsubscribe]] or [[opt_out]] macro in your HTML before sending."
        end
        do_request(MAILER_TO_LIST_PATH, :post, options, true)
      else
        do_request(MAILER_PATH, :post, options, true)
      end
    else
      raise MadMimiError, "You'll need to include either the [[tracking_beacon]] or [[peek_image]] macro in your HTML before sending."
    end
  end

  def send_plaintext(opt, plaintext)
    options = opt.dup
    options[:raw_plain_text] = plaintext
    if !options[:list_name].nil?
      if plaintext.include?('[[unsubscribe]]') || plaintext.include?('[[opt_out]]')
        do_request(MAILER_TO_LIST_PATH, :post, options, true)
      else
        raise MadMimiError, "You'll need to include either the [[unsubscribe]] or [[opt_out]] macro in your text before sending."
      end
    else
      do_request(MAILER_PATH, :post, options, true)
    end
  end

  private

  # Refactor this method asap
  def do_request(path, req_type = :get, options = {}, transactional = false)
    options = options.merge(default_opt)
    form_data = options.inject({}) { |m, (k, v)| m[k.to_s] = v; m }

    if transactional == true
      http = Net::HTTP.new(BASE_URL, 443)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    else
      http = Net::HTTP.new(BASE_URL, 80)
    end
    
    @response = http.start do |http|
      # Either Net::HTTP::Get or Net::HTTP::Post
      http_class = Net::HTTP.const_get(req_type.to_s.camelcase)
      req = http_class.new(path)
      req.set_form_data(form_data)
      http.request(req)
    end
    
    @response.value if raise_exceptions
    
    @response.body.strip

  end

  def build_csv(hash)
    if CSV.respond_to?(:generate_row)   # before Ruby 1.9
      buffer = ''
      CSV.generate_row(hash.keys, hash.keys.size, buffer)
      CSV.generate_row(hash.values, hash.values.size, buffer)
      buffer
    else                               # Ruby 1.9 and after
      CSV.generate do |csv|
        csv << hash.keys
        csv << hash.values
      end
    end
  end
end