require 'ldap'
require 'ldap/schema'
require 'will_paginate/array'
require 'digest'
require "open-uri"

class UsersController < ApplicationController
    include CacheableCSRFTokenRails

    @@cache_time = 120.hours
    @@user_treebase = "ou=Users,dc=csh,dc=rit,dc=edu"
    @@group_treebase = "ou=Groups,dc=csh,dc=rit,dc=edu"
    @@committee_treebase = "ou=Committees,dc=csh,dc=rit,dc=edu"
    @@search_vars = Set.new ['cn', 'description', 'displayName', 'mail', 'nickName',
        'plex', 'sn', 'uid', 'mobile', 'twitterName', 'github']

    # require the user to be logged in, except when getting profile pics so that 
    # APIs can call this
    before_action :require_webauth

    # Yo Man I heard you wanted some caching
    caches_action :list_years, expires_in: @@cache_time
    caches_action :list_groups, expires_in: @@cache_time
    caches_action :list_users, expires_in: @@cache_time, cache_path: Proc.new { |c| c.params }
    caches_action :group, expires_in: @@cache_time, cache_path: Proc.new { |c| c.params }
    caches_action :year, expires_in: @@cache_time, cache_path: Proc.new { |c| c.params }
    #caches_action :image, expires_in: @@cache_time, cache_path: Proc.new { |c| c.params }
    caches_action :search, expires_in: @@cache_time, cache_path: Proc.new { |c| c.params['search'] }

    caches_page :image

    # Checks to see if the user is behind WebAuth and sets
    # required variables
    def require_webauth
        @uid = request.env['WEBAUTH_USER']
    end

    # Searches LDAP for users
    def search
        @users = []
        filter = "(|"
        search_str = params[:search][:search].split(" ").join("*")
        Rails.logger.info {"search: '#{search_str}'" }
        @@search_vars.each { |var| filter << "(#{var}=*#{search_str}*)" }
        filter << ")"

        bind_ldap(true) do |ldap_conn|
            ldap_conn.search(@@user_treebase,  LDAP::LDAP_SCOPE_SUBTREE, filter, 
                             ["uid", "cn", "memberSince"]) do |entry|
                @users << entry.to_hash   
            end
        end

        # if only one result is returned, redirect to that user
        if @users.length == 1
            redirect_to "/user/#{@users[0]["uid"][0]}"
        else
            sort_by_date(@users)
            render 'list_users'
        end
    end

    # List all the users by newest members first
    def list_users
        @users = []
        params[:page] = "a" if params[:page] == nil
        attrs = ["uid", "cn", "memberSince"]
        bind_ldap(true) do |ldap_conn|
            ldap_conn.search(@@user_treebase, LDAP::LDAP_SCOPE_SUBTREE, 
                          "(uid=#{params[:page]}*)", attrs = attrs) do |entry|
                @users << entry.to_hash
            end
        end
        @users.sort! { |x,y| x["uid"] <=> y["uid"] }
        @title = "users"
        @current = params[:page]
        @url = "users"
    end

    # Lists all the groups sorted alphabetically
    def list_groups
        @groups = []
        bind_ldap(true) do |ldap_conn|
            ldap_conn.search(@@group_treebase, LDAP::LDAP_SCOPE_SUBTREE, 
                              "(cn=*)") do |entry|
                @groups << entry.to_hash
            end
        end
        @title = "groups"
        @groups.sort! { |x,y| x["cn"] <=> y["cn"] }
    end

    # Lists all the years for members
    def list_years
        @years = Time.new.month >= 8 ? (1994..Time.new.year).to_a.reverse : (1994...Time.new.year).to_a.reverse
        @title = "years"
    end

    # Returns the jpegPhoto for the given uid. The user can specify the size of
    # the image to return as well
    def image
        response.headers["Expires"] = 1.hour.from_now.httpdate
        Rails.logger.info { "cache miss for profile picture of #{params[:uid]}" }
        result = nil
        bind_ldap(false) do |ldap_conn|
            result = get_image(ldap_conn, params[:uid])
        end
        type, image = result

        if type == :gravatar # if no image is in LDAP
            url = "https://gravatar.com/avatar/#{Digest::MD5.hexdigest(image)}?size=200&d=mm"
            if @uid == params[:uid] # user is logged in through webauth and is viewing themself
                # steals the image from gravatar and uploads it to LDAP so we can do caching
                image = nil
                open(url, 'rb') do |name|
                    Rails.logger.info { "uploading #{@uid}'s image to LDAP" }
                    update = generate_image_update(name)
                    ldap_write(update, [], true)
                end
            end

            # always write the image so that it gets cached
            image = nil
            open(url, 'rb') { |f| image = f.read }
            send_data(image, filename: "#{params[:uid]}.jpg", type: "image/jpeg") 
        else # image is in LDAP
            send_data(image, filename: "#{params[:uid]}.jpg", type: "image/jpeg")
        end
    end

    def autocomplete
        @users = []
        bind_ldap(true) do |ldap_conn|
            ldap_conn.search(@@user_treebase, LDAP::LDAP_SCOPE_SUBTREE,
                             "(|(uid=*#{params[:term]}*)(cn=*#{params[:term]}*)
                             (mail=*#{params[:term]}*)(nickName=*#{params[:term]}*))",
                             ["uid", "cn"]) do |entry|
                hash = entry.to_hash
                uid = entry.to_hash["uid"][0]
                if hash["cn"].length > 0
                    @users << {value: uid, label: hash["cn"][0]}
                else
                    @users << {label: uid, value: uid}
                end
            end
        end
        Rails.logger.debug { @users[0..10] }
        render :json => @users[0..10]
    end

    def me
        @title = @uid
        bind_ldap(true) do |ldap_conn|
            ldap_conn.search(@@user_treebase, LDAP::LDAP_SCOPE_SUBTREE, "(uid=#{@uid})") do |entry|
                @user = format_fields entry.to_hash
                get_attrs(@user["objectClass"], ldap_conn).each do |attr|
                    @user[attr[0]] = (@user[attr[0]] == nil) ? [nil, attr[1]] : [@user[attr[0]], attr[1]]
                end
                @user = @user.except("uidNumber", "homeDirectory",
                                 "diskQuotaSoft", "diskQuotaHard", 
                                 "gidNumber", "objectClass", "uid", "ou",
                                 "userPassword", "l", "o", 
                                 "conditional", "gecos")
            end

            @groups = get_groups(ldap_conn, @user["dn"][0])           
            @positions = get_positions(ldap_conn, @user["dn"][0], @groups)

            status = [
                @groups.include?("active") ? :active : :not_active,
                @groups.include?("current_student") ? :current_student : :alumni,
                @groups.include?("onfloor") ? :onfloor : :offfloor,
                @groups.include?("honorarymembers") ? :honorary : :nonhonorary,
                @groups.include?("disabled") ? :disabled : :enabled]
            @status = get_status status    
        end
    end

    # Displays all the information for the given user
    def user 
        return redirect_to :me if @uid == params[:uid]
        @user = nil
        bind_ldap(true) do |ldap_conn|
            ldap_conn.search(@@user_treebase, LDAP::LDAP_SCOPE_SUBTREE, "(uid=#{params[:uid]})") do |entry|
                @user = format_fields entry.to_hash.except(
                    "objectClass", "uidNumber", "homeDirectory",
                    "diskQuotaSoft", "diskQuotaHard", "gidNumber")
            end
            if @user == nil
                return redirect_to root_path
            else
                @title = @user["uid"][0]
                @groups = get_groups(ldap_conn, @user["dn"][0])
                @positions = get_positions(ldap_conn, @user["dn"][0], @groups)

                status = [
                    @groups.include?("active") ? :active : :not_active,
                    @groups.include?("current_student") ? :current_student : :alumni,
                    @groups.include?("onfloor") ? :onfloor : :offfloor,
                    @groups.include?("honorarymembers") ? :honorary : :nonhonorary,
                    @groups.include?("disabled") ? :disabled : :enabled]
                @status = get_status status
            end
        end
    end

    def generate_image_update(img_file)
        @attr_key = 'jpegPhoto'
        image = MiniMagick::Image.read(img_file)
        max = [image[:width].to_f, image[:height].to_f].max
        Rails.logger.debug { "image max size: #{max}" }
        max_size = 250
        if max > max_size
            height = (image[:height].to_f / (max / max_size)).to_i
            width = (image[:width].to_f / (max / max_size)).to_i
            Rails.logger.debug { "Resizing user to #{width}x#{height}" }
            image.resize("#{height}x#{width}")
            update = LDAP.mod(LDAP::LDAP_MOD_REPLACE | LDAP::LDAP_MOD_BVALUES, 
                          @attr_key, [image.to_blob])
        else
            update = LDAP.mod(LDAP::LDAP_MOD_REPLACE | LDAP::LDAP_MOD_BVALUES, 
                          @attr_key, [img_file.read])
        end
        update
    end


    def ldap_write(update, real_input, image_upload)
        result = {"key" => @attr_key}
        dn = "uid=#{@uid},#{@@user_treebase}"
        bind_ldap(true) do |ldap_conn|
        begin
            result["single"] = is_single @attr_key, ldap_conn
            ldap_conn.modify(dn, [update])
            result["success"] = true
            result["value"] = real_input if real_input != nil
            expire_cache(ldap_conn, dn, image_upload, @attr_key)
        rescue LDAP::Error => e
            Rails.logger.error "Error modifying ldap for #{@uid}, #{e}"
            ldap_conn = create_connection
            result["success"] = false
            result["error"] = e.to_s
            ldap_conn.search(@@user_treebase, LDAP::LDAP_SCOPE_SUBTREE, 
                              "(uid=#{@uid})", [@attr_key]) do |entry|
                user = format_fields entry.to_hash
                result["value"] = user[@attr_key] != nil ? user[@attr_key] : ""
                if (@attr_key == "birthday" || @attr_key == "memberSince") && 
                    result["value"][0] != nil
                    result["value"] = real_input
                end
            end
        end
    end
        result
    end


    # Updates the given user's attributes
    def update
        @attr_key = nil
        attr_value = []
        real_input = []

        if params['picture'] != nil
            update = generate_image_update(params[:picture])
            ldap_write(update, real_input, true)
            # uploading images refreshes the screen while everything else is ajax / js 
            redirect_to :me
        else
            params.except("controller", "action", "utf8").each do |key, value|
                @attr_key = key.split("-")[0]
                if @attr_key == "birthday"
                    begin
                        attr_value << DateTime.strptime(value.to_s, "%m/%d/%Y").
                            strftime('%Y%m%d%H%M%S-0400') 
                        real_input << value if value != ""
                    rescue Exception => e
                        Rails.logger.warn "Error parsing birthday input #{value.to_s}, #{e}"
                        attr_value << "BAD"
                    end
                else
                    attr_value << value if value != ""
                    real_input << value if value != ""
                end
            end
            update = LDAP.mod(LDAP::LDAP_MOD_REPLACE, @attr_key, attr_value)
            result = ldap_write(update, real_input, false)
            render text: "var status = '#{result.to_s.gsub(/=>/, ":")}';"
        end
    end

    # Gets all the users for the given group
    def group
        params[:page] = "a" if params[:page] == nil
        @users = []
        filter = "(cn=#{params[:group]})"
        bind_ldap(true) do |ldap_conn|
            ldap_conn.search(@@group_treebase, LDAP::LDAP_SCOPE_SUBTREE, filter) do |entry|
                @users = entry.to_hash["member"].to_a
                @title = entry.to_hash["cn"][0]
            end
            @users = [] if @users == [""]
            filter = "(|"
            if @users.length > 100
                @current = params[:page]
                @url = "group/#{params[:group]}"
                @users.each do |dn| 
                    if dn.split(",")[0].split("=")[1][0] == params[:page]
                        filter += "(uid=#{dn.split(",")[0].split("=")[1]})"
                    end
                end
            else
                @users.each { |dn| filter += "(uid=#{dn.split(",")[0].split("=")[1]})" }
            end
            filter += ")"
            @users = []
            attrs = ["uid", "cn", "memberSince"]
            ldap_conn.search(@@user_treebase, LDAP::LDAP_SCOPE_SUBTREE, filter, attrs) do |entry|
                @users << entry.to_hash
            end
            @users.sort! { |x,y| x["uid"] <=> y["uid"] }
        end
        render 'list_users'
    end

    # Gets all the user for each school year. Aug - May
    def year
        @users = []
        year = params[:year].to_i
        attrs = ["uid", "cn", "memberSince"]
        filter  = "(&(memberSince>=#{year}0801010101-0400)(memberSince<=#{year + 1}0801010101-0400))"
        bind_ldap(true) do |ldap_conn|
            ldap_conn.search(@@user_treebase, LDAP::LDAP_SCOPE_SUBTREE, filter, attrs) do |entry|
                @users << entry.to_hash
            end
        end
        sort_by_date(@users)
        @title = "#{params[:year]} - #{params[:year].to_i + 1}"
        render 'list_users'
    end

    # Allows RTPs and JD to clear the page's cache
    def clear_cache
        bind_ldap(true) do |ldap_conn|
            dn = "uid=#{@uid},#{@@user_treebase}"
            if @uid == "jd" || get_groups(ldap_conn, dn).include?("rtp")
                Rails.cache.clear
                flash[:info] = "Cache has been cleared"
            else
                flash[:warning] = "You do not have permission to clear cache"
            end
        end
        redirect_to root_path
    end

    private

        def get_status status
            case status
            when [:active, :current_student, :offfloor, :nonhonorary, :enabled]
                return "Active off-floor status"
            when [:active, :current_student, :onfloor, :nonhonorary, :enabled]
                return "Active on-floor status"
            when [:not_active, :current_student, :offfloor, :nonhonorary, :enabled]
                return "Inactive off-floor status"
            when [:not_active, :current_student, :onfloor, :nonhonorary, :enabled]
                return "Inactive on-floor status"
            when [:not_active, :alumni, :offfloor, :nonhonorary, :enabled]
                return "Alumni"
            when [:not_active, :alumni, :onfloor, :nonhonorary, :enabled]
                return "Alumni"
            when [:not_active, :current_student, :offfloor, :honorary, :enabled]
                return "Honorary"
            when [:not_active, :alumni, :offfloor, :honorary, :enabled]
                return "Honorary"
            when [:active, :current_student, :offfloor, :nonhonorary, :disabled]
                return "Active off-floor status - Account Disabled"
            when [:active, :current_student, :onfloor, :nonhonorary, :disabled]
                return "Active on-floor status - Account Disabled"
            when [:not_active, :current_student, :offfloor, :nonhonorary, :disabled]
                return "Inactive off-floor status - Account Disabled"
            when [:not_active, :current_student, :onfloor, :nonhonorary, :disabled]
                return "Inactive on-floor status - Account Disabled"
            when [:not_active, :alumni, :offfloor, :nonhonorary, :disabled]
                return "Alumni - Account Disabled"
            when [:not_active, :alumni, :onfloor, :nonhonorary, :disabled]
                return "Alumni - Account Disabled"
            when [:not_active, :current_student, :offfloor, :honorary, :disabled]
                return "Honorary - Account Disabled"
            when [:not_active, :alumni, :offfloor, :honorary, :disabled]
                return "Honorary - Account Disabled"
	    else
		return "Error in LDAP Group Configuration, Contact an RTP"
            end
        end

        def sort_by_date(users)
            users.sort! do |x,y| 
                if !x["memberSince"]
                    1
                elsif !y["memberSince"]
                    -1
                else
                    y["memberSince"] <=> x["memberSince"]
                end
            end
        end

        # Log who is viewing what page
        def log_view
            case action_name
            when 'list_users'
                Rails.logger.views.info "#{@uid} list_users"
            when 'list_groups'
                Rails.logger.views.info "#{@uid} list_groups"
            when 'list_years'
                Rails.logger.views.info "#{@uid} list_years"
            when 'me'
                Rails.logger.views.info "#{@uid} user:#{@uid}"
            when 'user'
                Rails.logger.views.info "#{@uid} user:#{params[:uid]}"
            when 'update'
                Rails.logger.views.info "#{@uid} update:#{@attr_key}"
            when 'group'
                Rails.logger.views.info "#{@uid} group:#{params[:group]}"
            when 'year'
                Rails.logger.views.info "#{@uid} year:#{params[:year]}"
            when 'search'
                Rails.logger.views.info "#{@uid} search:#{params[:search][:search]}"
            end
        end

        def format_fields map
            new_map = Hash.new
            new_map["uid"] = map["uid"] if map.key? "uid"
            new_map["cn"] = map["cn"] if map.key? "cn"
            new_map["mail"] = map["mail"] if map.key? "mail"
            new_map["mobile"] = map["mobile"] if map.key? "mobile"
            new_map["drinkBalance"] = map["drinkBalance"] if map.key? "drinkBlance"
            new_map["birthday"] = map["birthday"] if map.key? "birthday"
            new_map["housingPoints"] = map["housingPoints"] if map.key? "housingPoints"
            new_map["sn"] = map["sn"] if map.key? "sn"
            new_map["homepageURL"] = map["homepageURL"] if map.key? "homepageURL"
            new_map["blogURL"] = map["blogURL"] if map.key? "blogURL"
            map.each do |key, value| 
                new_map[key] = value if !new_map.key? key
            end

            return new_map
        end

        # Gets the ldap connection for the given user using the kerberos auth
        # provided by webauth
        # krb: true if to use kerberos auth to LDAP, password otherwise
        def bind_ldap(krb)
            start_time = Time.now.to_f * 1000
            ldap_conn = LDAP::SSLConn.new(host = Global.ldap.host, port = Global.ldap.port)
            ldap_conn.set_option( LDAP::LDAP_OPT_PROTOCOL_VERSION, 3 )

            if krb
                ENV['KRB5CCNAME'] = request.env['KRB5CCNAME']
                Rails.logger.info { "binding with #{@uid}" }
                ldap_conn.sasl_bind('', '')
            else
                Rails.logger.info { "binding with #{Global.ldap.username}" }
                ldap_conn.bind(Global.ldap.username, Global.ldap.password)
            end

            yield ldap_conn
            ldap_conn.unbind()
            end_time = Time.now.to_f * 1000
            Rails.logger.info { "LDAP time: #{(end_time - start_time).round(2)}ms" }
        end

        # deals with expiring all the needed cache when an update happens. Only the
        # affected cache is expired
        def expire_cache(ldap_conn, dn, image_upload, attr_key)
            if image_upload
                Rails.logger.info { "expiring page #{@uid}" }
                expire_action action: :image, uid: @uid
                expire_page action: :image, uid: @uid, format: "jpeg"
            elsif attr_key == 'cn'
                expire_action action: :list_users, page: @uid[0]
                get_groups(ldap_conn, dn).each do |cn|
                    expire_action action: :group, group: cn
                    expire_action action: :group, group: cn, page: @uid[0]
                end
                expire_action action: :year, year: get_year(ldap_conn, @uid)
            elsif @@search_vars.include? attr_key
                expire_action action: :search
            end 
        end

        # Gets the positions that the user holds and caches the result. 
        # ldap_conn: the LDAP connection to use
        # dn: the dn of the user to look up
        # groups: the LDAP groups that the user belongs to, used for RTP and
        #   drink admin positions
        def get_positions(ldap_conn, dn, groups)
            Rails.cache.fetch("positions-#{dn}", expires_in: @@cache_time) do
                Rails.logger.debug { "Getting positions for #{dn}" }
                positions = []
                ldap_conn.search(@@committee_treebase, LDAP::LDAP_SCOPE_SUBTREE, "(head=#{dn})") do |entry|
                    cn = entry.to_hash['cn'][0]
                    if cn == "Eboard"
                        positions << "Chairman"
                    else
                        positions << "#{entry.to_hash['cn'][0]} Director"
                    end
                end
                positions << "RTP" if groups.include? "rtp"
                positions << "Drink Admin" if groups.include? "drink"
                positions
            end
        end

        # Gets the groups that the given user is a part of and caches them
        def get_groups(ldap_conn, dn)
            Rails.cache.fetch("groups-#{dn}", expires_in: @@cache_time) do
                Rails.logger.debug { "Getting groups for #{dn}" }
                groups = []
                ldap_conn.search(@@group_treebase, LDAP::LDAP_SCOPE_SUBTREE, "(member=#{dn})") do |entry|
                    groups << entry.to_hash["cn"][0]
                end
                groups
            end
        end

        # Gets the year that the person is from. This is used in clearing the 
        # cache for the given year
        def get_year(ldap_conn, uid)
            Rails.cache.fetch("member-since-#{uid}", expires_in: @@cache_time) do
                Rails.logger.debug { "Getting year for #{uid}" }
                member_since = nil
                ldap_conn.search(@@user_treebase, LDAP::LDAP_SCOPE_SUBTREE, "(uid=#{uid})", ["memberSince"]) do |entry|
                    member_since = entry.to_hash['memberSince']
                end
                year = member_since[0][0..3] if member_since != nil && member_since.length >= 1
                year 
            end
        end

        # Gets the image profile picture for a given user. If the user does not
        # have a jpegPhoto attribute in LDAP, then gravatar is used with their
        # @csh.rit.edu email. This is not cached since the action is already
        # being cached.
        # ldap_conn: the ldap connection to use
        # uid: the uid of the user to get the image of
        # Return:
        #   type: either :gravatar or :image depending on what the source of the
        #       profile pic is
        #   result: the email to use or the actual image from LDAP
        def get_image(ldap_conn, uid)
            Rails.logger.debug { "Getting image for #{uid}" }
            image = nil
            ldap_conn.search(@@user_treebase, LDAP::LDAP_SCOPE_SUBTREE, 
                            "(uid=#{uid})", ["jpegPhoto"]) do |entry|
                if entry["jpegPhoto"] != nil && entry["jpegPhoto"][0].length > 0
                    image = entry["jpegPhoto"][0]
                end
            end
            if !image
                return :gravatar, "#{uid}@csh.rit.edu"
            else
                return :image, image
            end
        end


        # Gets the attributes that the given user can have along with info
        # on if there can be multiple of the value
        # object_classes: the object classes that the user belongs to, used
        #   to get the values allowed
        def get_attrs(object_classes, ldap_conn)
            Rails.cache.fetch("object-classes-#{object_classes}", expires_in: @@cache_time) do
                Rails.logger.debug { "Getting attributes for #{object_classes}" }
                schema = ldap_conn.schema()
                attr_set = Set.new
                real_attrs = []

                object_classes.each do |oc|
                    if oc == "person"
                        schema.must(oc).each { |attr| attr_set.add attr }
                    elsif oc == "posixAccount"
                        schema.must(oc).each { |attr| attr_set.add attr }
                        schema.may(oc).each { |attr| attr_set.add attr }
                    elsif oc == "drinkUser"
                        schema.must(oc).each { |attr| attr_set.add attr }
                    elsif oc == "ibuttonUser"
                        schema.may(oc).each { |attr| attr_set.add attr }
                    elsif oc == "profiledMember"
                        schema.may(oc).each { |attr| attr_set.add attr }
                    elsif oc == "houseMember"
                        schema.may(oc).each { |attr| attr_set.add attr }
                    elsif oc == "ritStudent"
                        schema.must(oc).each { |attr| attr_set.add attr }
                        schema.may(oc).each { |attr| attr_set.add attr }
                    elsif oc == "inetOrgPerson"
                        schema.may(oc).each { |attr| attr_set.add attr }
                    end
                end
                schema["attributeTypes"].each do |s|
                    name = s.split(" ")[3][1..-2]
                    # deals with when attributes have aliases
                    n = s.split("NAME")[1].split("DESC")[0].strip
                    name = n.split("'")[1] if n[0] == "("

                    if attr_set.include? name.strip
                        if s.split(" ")[-2] == "SINGLE-VALUE"
                            real_attrs << [name, :single]
                        else
                            real_attrs << [name, :multiple]
                        end
                    end
                end
                real_attrs
            end
        end

        # used in the update method to determine if the variable can have 
        # multiple variables
        # attr: The attribute name to test
        # ldap_conn: the LDAP connection to use
        # Returns: true of false if the variable is single
        def is_single (attr, ldap_conn)
            Rails.cache.fetch("is-single-#{attr}", expires_in: @@cache_time) do
                Rails.logger.debug { "Getting single status for #{attr}" }
                result = false
                schema = ldap_conn.schema()
                schema["attributeTypes"].each do |s|
                    name = s.split(" ")[3][1..-2]
                    # deals with when attributes have aliases
                    n = s.split("NAME")[1].split("DESC")[0].strip
                    name = n.split("'")[1] if n[0] == "("
                    result = s.split(" ")[-2] == "SINGLE-VALUE" if name == attr
                end
                result
            end
        end
end
