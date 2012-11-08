# encoding: UTF-8

require 'wice_grid_misc.rb'
require 'wice_grid_core_ext.rb'
require 'grid_renderer.rb'
require 'table_column_matrix.rb'
require 'helpers/wice_grid_view_helpers.rb'
require 'helpers/wice_grid_misc_view_helpers.rb'
require 'helpers/wice_grid_serialized_queries_view_helpers.rb'
require 'helpers/wice_grid_view_helpers.rb'
require 'helpers/js_calendar_helpers.rb'
require 'grid_output_buffer.rb'
require 'wice_grid_controller.rb'
require 'wice_grid_spreadsheet.rb'
require 'wice_grid_serialized_queries_controller.rb'
require 'view_columns/column_processor_index.rb'
require 'view_columns.rb'
require 'kaminari.rb'


ActionController::Base.send(:helper_method, :wice_grid_custom_filter_params)

module Wice

  class WiceGridEngine < ::Rails::Engine

    initializer "wice_grid_railtie.configure_rails_initialization" do |app|

      ActiveSupport.on_load :action_controller do
        ActionController::Base.send(:include, Wice::Controller)
      end

      ActiveSupport.on_load :active_record do
        ActiveRecord::ConnectionAdapters::Column.send(:include, ::Wice::WiceGridExtentionToActiveRecordColumn)
        ActiveRecord::Base.send(:include, ::Wice::MergeConditions)
      end

      ActiveSupport.on_load :action_view do
        ::ActionView::Base.class_eval { include Wice::GridViewHelper }
        [ActionView::Helpers::AssetTagHelper,
         ActionView::Helpers::TagHelper,
         ActionView::Helpers::JavaScriptHelper,
         ActionView::Helpers::FormTagHelper].each do |m|
          JsCalendarHelpers.send(:include, m)
        end

        ViewColumn.load_column_processors
        require 'wice_grid_serialized_query.rb'

        # It is here only until this pull request is pulled: https://github.com/amatsuda/kaminari/pull/267
        require 'kaminari_monkey_patching.rb'
      end
    end
  end

  class WiceGrid

    attr_reader :klass, :name, :resultset, :custom_order, :query_store_model
    attr_reader :ar_options, :status, :export_to_csv_enabled, :csv_file_name, :csv_field_separator, :saved_query
    attr_writer :renderer
    attr_accessor :output_buffer, :view_helper_finished, :csv_tempfile

    # core workflow methods START

    def initialize(klass_or_relation, controller, opts = {})  #:nodoc:
      @controller = controller
      @logger = opts[:logger] || Rails.logger

      @relation = klass_or_relation
      @klass = klass_or_relation.is_a?(ActiveRecord::Relation) ?
        klass_or_relation.klass :
        klass_or_relation

      unless @klass.kind_of?(Class) && @klass.ancestors.index(ActiveRecord::Base)
        raise WiceGridArgumentError.new("ActiveRecord model class (second argument) must be a Class derived from ActiveRecord::Base")
      end

      # validate :with_resultset & :with_paginated_resultset
      [:with_resultset, :with_paginated_resultset].each do |callback_symbol|
        unless [NilClass, Symbol, Proc].index(opts[callback_symbol].class)
          raise WiceGridArgumentError.new(":#{callback_symbol} must be either a Proc or Symbol object")
        end
      end

      opts[:order_direction].downcase! if opts[:order_direction].kind_of?(String)

      # validate :order_direction
      if opts[:order_direction] && ! (opts[:order_direction] == 'asc'  ||
                                      opts[:order_direction] == :asc   ||
                                      opts[:order_direction] == 'desc' ||
                                      opts[:order_direction] == :desc)
        raise WiceGridArgumentError.new(":order_direction must be either 'asc' or 'desc'.")
      end

      # options that are understood
      @options = {
        :conditions           => nil,
        :csv_file_name        => nil,
        :csv_field_separator  => Defaults::CSV_FIELD_SEPARATOR,
        :custom_order         => {},
        :enable_export_to_csv => Defaults::ENABLE_EXPORT_TO_CSV,
        :group                => nil,
        :include              => nil,
        :joins                => nil,
        :name                 => Defaults::GRID_NAME,
        :order                => nil,
        :order_direction      => Defaults::ORDER_DIRECTION,
        :page                 => 1,
        :per_page             => Defaults::PER_PAGE,
        :saved_query          => nil,
        :total_entries        => nil,
        :with_paginated_resultset  => nil,
        :with_resultset       => nil,

        # Sphinx begin
        :index                => nil,
        :index_weights        => nil,
        :search_text          => nil,
        :match_mode           => nil,
        :rank_mode            => nil,
        :star                 =>nil,
        :with                 => nil,
        :without              => nil,
        :sort_mode            => nil,
        :is_sphinx            => false,
        :is_facets            => false
        # Sphinx end
      }

      # validate parameters
      opts.assert_valid_keys(@options.keys)

      @options.merge!(opts)
      @export_to_csv_enabled = @options[:enable_export_to_csv]
      @csv_file_name = @options[:csv_file_name]
      @csv_field_separator = @options[:csv_field_separator]

      case @name = @options[:name]
      when String
      when Symbol
        @name = @name.to_s
      else
        raise WiceGridArgumentError.new("name of the grid should be a string or a symbol")
      end
      raise WiceGridArgumentError.new("name of the grid can only contain alphanumeruc characters") unless @name =~ /^[a-zA-Z\d_]*$/

      @table_column_matrix = TableColumnMatrix.new
      @table_column_matrix.default_model_class = @klass

      @ar_options = {}
      @status = HashWithIndifferentAccess.new

      if @options[:order]
        # Sphinx begin
        if @options[:sort_mode].blank?
          @status[:order_direction] = @options[:order_direction].to_s
          @status[:order] = @options[:order].to_s
        else
          @status[:sort_mode] = @options[:sort_mode]
          @status[:order] = @options[:order]
        end
        # Sphinx end
      end
      @status[:total_entries] = @options[:total_entries]
      @status[:per_page] = @options[:per_page]
      @status[:page] = @options[:page]
      @status[:conditions] = @options[:conditions]
      @status[:f] = @options[:f]

      # Sphinx begin
      @status[:index] = @options[:index] unless @options[:index].blank?
      @status[:index_weights] = @options[:index_weights] unless @options[:index_weights].blank?
      @status[:search_text] = @options[:search_text] unless  @options[:search_text].blank?
      @status[:match_mode] = @options[:match_mode] unless  @options[:match_mode].blank?
      @status[:with] = @options[:with] unless  @options[:with].blank?
      @status[:without] = @options[:without] unless  @options[:without].blank?
      @status [:is_sphinx]= @options[:is_sphinx]
      @status [:is_facets]= @options[:is_facets]
      @klass.define_indexes if @status[:is_sphinx] or @status[:is_facets]
      @status[:indexes] = collect_indexes if @status[:is_sphinx] or @status[:is_facets]
      # Sphinx end

      process_loading_query
      process_params

      @ar_options_formed = false

    end

    # A block executed from within the plugin to process records of the current page.
    # The argument to the callback is the array of the records. See the README for more details.
    def with_paginated_resultset(&callback)
      @options[:with_paginated_resultset] = callback
    end

    # A block executed from within the plugin to process all records browsable through
    # all pages with the current filters. The argument to
    # the callback is a lambda object which returns the list of records when called. See the README for the explanation.
    def with_resultset(&callback)
      @options[:with_resultset] = callback
    end

    def process_loading_query #:nodoc:
      @saved_query = nil
      if params[name] && params[name][:q]
        @saved_query = load_query(params[name][:q])
        params[name].delete(:q)
      elsif @options[:saved_query]
        if @options[:saved_query].is_a? ActiveRecord::Base
          @saved_query = @options[:saved_query]
        else
          @saved_query = load_query(@options[:saved_query])
        end
      else
        return
      end

      unless @saved_query.nil?
        params[name] = HashWithIndifferentAccess.new if params[name].blank?
        [:f, :order, :order_direction].each do |key|
          if @saved_query.query[key].blank?
            params[name].delete(key)
          else
            params[name][key] = @saved_query.query[key]
          end
        end
      end
    end

    def process_params  #:nodoc:
      if this_grid_params
        @status.merge!(this_grid_params)
        @status.delete(:export) unless self.export_to_csv_enabled
      end
    end

    def declare_column(column_name, model, custom_filter_active, table_alias)  #:nodoc:
      if model # this is an included table
        column = @table_column_matrix.get_column_by_model_class_and_column_name(model, column_name)
        raise WiceGridArgumentError.new("Column '#{column_name}' is not found in table '#{model.table_name}'!") if column.nil?
        main_table = false
        table_name = model.table_name
      else
        column = @table_column_matrix.get_column_in_default_model_class_by_column_name(column_name)
        if column.nil?
          raise WiceGridArgumentError.new("Column '#{column_name}' is not found in table '#{@klass.table_name}'! " +
            "If '#{column_name}' belongs to another table you should declare it in :include or :join when initialising " +
            "the grid, and specify :model in column declaration.")
        end
        main_table = true
        table_name = @table_column_matrix.default_model_class.table_name
      end

      if column
        conditions, current_parameter_name = column.wg_initialize_request_parameters(@status[:f], main_table, table_alias, custom_filter_active)
        if @status[:f] && conditions.blank?
          @status[:f].delete(current_parameter_name)
        end

        @table_column_matrix.add_condition(column, conditions)
        [column, table_name , main_table]
      else
        nil
      end
    end

    # Sphinx begin
    def collect_indexes
      all_indexes =[]

      for index in @klass.sphinx_indexes.first.fields
        all_indexes << index.unique_name
      end

      all_indexes
    end

    def form_ar_options(opts = {})  #:nodoc:
      return form_ar_options_for_sphinx if @status[:is_sphinx] || @status[:is_facets]

      return if @ar_options_formed
      @ar_options_formed = true unless opts[:forget_generated_options]

      # validate @status[:order_direction]
      @status[:order_direction] = case @status[:order_direction]
      when /desc/i
        'desc'
      when /asc/i
        'asc'
      else
        ''
      end

      # conditions
      if @table_column_matrix.generated_conditions.size == 0
        @status.delete(:f)
      end

      @ar_options[:conditions] = klass.send(:merge_conditions, @status[:conditions], * @table_column_matrix.conditions )
      # conditions processed

      if (! opts[:skip_ordering]) && @status[:order]
        @ar_options[:order] = add_custom_order_sql(complete_column_name(@status[:order]))

        @ar_options[:order] += ' ' + @status[:order_direction]
      end

      if self.output_html?
        @ar_options[:per_page] = if all_record_mode?
          # reset the :pp value in all records mode
          @status[:pp] = count_resultset_without_paging_without_user_filters
        else
          @status[:per_page]
        end

        @ar_options[:page] = @status[:page]
        @ar_options[:total_entries] = @status[:total_entries] if @status[:total_entries]
      end

      @ar_options[:joins]   = @options[:joins]
      @ar_options[:include] = @options[:include]
      @ar_options[:group] = @options[:group]
    end

    def form_ar_options_for_sphinx(opts = {})  #:nodoc:
      return if @ar_options_formed
      @ar_options_formed = true unless opts[:forget_generated_options]

      # conditions
      if @table_column_matrix.generated_conditions.size == 0 and @status[:f].blank?
        @logger.debug "should only do this with no filters given"
        @status.delete(:f)
      end

      if !opts[:skip_ordering] && @status[:order]
        @logger.debug "form_ar-options_status_inspect \n#{@status.inspect}"
        
        unless @status[:sort_mode].blank?
          @ar_options[:order] = get_column_name(@status[:order])
          
          if @status[:order_direction].blank?
            @ar_options[:sort_mode] = @status[:sort_mode]
          else
            @ar_options[:sort_mode] = @status[:order_direction].to_sym
          end
        else
          @ar_options[:sql_order] = @status[:order]
          @ar_options[:sql_order] = "#{@ar_options[:sql_order]} " \
            "#{@status[:order_direction]}" \
            unless @status[:order_direction].blank?
        end
        
        @logger.debug "ar_options_order : #{@ar_options[:order]} and " \
          "sort_mode : #{@ar_options[:sort_mode]} and sql_order : " \
          "#{@ar_options[:sql_order]} and order_direction : " \
          "#{@ar_options[:order_direction]}" 
      end

      if self.output_html? or self.output_csv?
        @ar_options[:per_page] = @status[:pp] || @status[:per_page]
        @ar_options[:page] = @status[:page]
        @ar_options[:total_entries] = @status[:total_entries] if @status[:total_entries]
      end

      add_filter_to_conditions
      add_filter_to_with

      @ar_options[:index] = @options[:index] unless @options[:index].blank?
      @ar_options[:index_weights] = @options[:index_weights] unless @options[:index_weights].blank?
      @ar_options[:match_mode] = @options[:match_mode] unless @options[:match_mode].blank?
      @ar_options[:joins]   = @options[:joins] unless  @options[:joins].blank?
      @ar_options[:include] = @options[:include]  unless  @options[:include].blank?
      @ar_options[:with] = @options[:with]  unless  @options[:with].blank?
      @ar_options[:without] = @options[:without]  unless  @options[:without].blank?
      @ar_options[:conditions] = @options[:conditions] unless @options[:conditions].blank?
      @ar_options[:star] = @options[:star] unless @options[:star].blank?
      @ar_options[:retry_stale] = @options[:retry_stale] unless @options[:retry_stale].blank?
      @logger.debug "ar_options_inspect \n #{@ar_options.inspect}"
      @ar_options
    end

    def get_column_name(key)
      if key =~/\./
        new_key = key.gsub(/\./,"_")
        return new_key.to_sym
      else
        return key.to_sym
      end
    end
    
    def add_filter_to_conditions
      if @status[:f]
        @logger.debug "i have conditional filters i'll process them....."
        @status[:f].each_pair { |key, val|
          column  = get_column_name(key)
          @logger.debug "index: #{@status.inspect} key : #{key} column: #{column} equal: #{@status.include?(column)}"
          if @status[:indexes].include?(column)
            @logger.debug "found a match...adding conditions"

            unless column == :first_name
              @options[:conditions][column] = val
            end

            @options[:star] = true if @options[:star].blank?
            @options[:sortable] = true if @options[:sortable].blank?
            @options[:retry_stale]= true if @options[:retry_stale].blank?
          end

        }

      end
    end

    def add_filter_to_with
      if @status[:f]
        @logger.debug "i have filter i'll process them..... is_sphinx : #{@status[:is_sphinx]}.....is_facet : #{@status[:is_facets]}"
        @status[:f].each_pair { |key, val|

          @logger.debug "processing..."
          column = get_column_name(key)
          unless @status[:indexes].include?(column)
            @logger.debug "got column name #{column}...val #{val.class}"
            if val.is_a?(Hash)
              @logger.debug "val : #{val} is_sphinx : #{@status[:is_sphinx]}.....is_facet : #{@status[:is_facets]}"
              range =[]
              val.each_value {|v| range << v }
              
              if range.size < 2
                range << range[0]
              end

              if ParseDate.parsedate(range[0])[0].blank?
                range[0] = range[0].to_f
                range[1] = range[1].to_f
              else
                range[0] = Time.parse(range[0].to_s)         # Time.mktime(dt.year, dt.month, dt.day, dt.hour, dt., 0, 0) if range.first.is_a?(DateTime)
                range[1] = Time.parse(range[1].to_s) + 1.day #Time.mktime(range.last.year, range.last.month, range.last.day, 0, 0, 0, 0) if range.last.is_a?(DateTime)
              end

              @options[:with][column] = range.first..range.last if @options[:with][column].blank?
            elsif val.is_a?(Array)
              @options[:with][column] = val.first if @options[:with][column].blank?
            else
              @options[:with][column] = val if @options[:with][column].blank?
            end

            @logger.debug ":with : #{@options[:with][column]}"
          end
        }
      end
    end

    # TO DO: what to do with other @ar_options values?
    def read  #:nodoc:
      return read_with_sphinx if @status[:is_sphinx] || @status[:is_facets]

      form_ar_options
      @klass.unscoped do
        @resultset = if self.output_csv?
          # @relation.find(:all, @ar_options)
          @relation.
            includes(@ar_options[:include]).
            joins(   @ar_options[:joins]).
            order(   @ar_options[:order]).
            where(   @ar_options[:conditions])

        else
          # p @ar_options
          @relation.
            page(    @ar_options[:page]).
            per(     @ar_options[:per_page]).
            includes(@ar_options[:include]).
            joins(   @ar_options[:joins]).
            order(   @ar_options[:order]).
            where(   @ar_options[:conditions])

        end
      end
      invoke_resultset_callbacks
    end

    def read_with_sphinx  #:nodoc:
      form_ar_options_for_sphinx
      
      @klass.unscoped do
        @resultset =  @status[:is_sphinx] ? @klass.search(@status[:search_text], @ar_options) : @klass.facets(@ar_options)
        @logger.debug "RESULT_SET : #{@resultset.inspect}" if @status[:is_facets]
        @resultset
      end
    end
    # Sphinx end

    # core workflow methods END

    # Getters

    def filter_params(view_column)  #:nodoc:
      column_name = view_column.attribute_name_fully_qualified_for_all_but_main_table_columns
      if @status[:f] && @status[:f][column_name]
        @status[:f][column_name]
      else
        {}
      end
    end

    def resultset  #:nodoc:
      self.read unless @resultset # database querying is late!
      @resultset
    end

    def each   #:nodoc:
      self.read unless @resultset # database querying is late!
      @resultset.each do |r|
        yield r
      end
    end

    def ordered_by?(column)  #:nodoc:
      return nil if @status[:order].blank?
      if column.main_table && ! offs = @status[:order].to_s().index('.')
        @status[:order] == column.attribute
      else
        @status[:order] == column.table_alias_or_table_name + '.' + column.attribute
      end
    end

    def ordered_by  #:nodoc:
      @status[:order]
    end


    def order_direction  #:nodoc:
      @status[:order_direction]
    end

    def filtering_on?  #:nodoc:
      not @status[:f].blank?
    end

    def filtered_by  #:nodoc:
      @status[:f].nil? ? [] : @status[:f].keys
    end

    def filtered_by?(view_column)  #:nodoc:
      @status[:f].nil? ? false : @status[:f].has_key?(view_column.attribute_name_fully_qualified_for_all_but_main_table_columns)
    end

    def get_state_as_parameter_value_pairs(including_saved_query_request = false) #:nodoc:
      res = []
      unless status[:f].blank?
        Wice::WgHash.parameter_names_and_values(status[:f], [name, 'f']).collect do |param_name, value|
          if value.is_a?(Array)
            param_name_ar = param_name + '[]'
            value.each do |v|
              res << [param_name_ar, v]
            end
          else
            res << [param_name, value]
          end
        end
      end

      if including_saved_query_request && @saved_query
        res << ["#{name}[q]", @saved_query.id ]
      end

      [:order, :order_direction].select{|parameter|
        status[parameter]
      }.collect do |parameter|
        res << ["#{name}[#{parameter}]", status[parameter] ]
      end

      res
    end

    def count  #:nodoc:
      form_ar_options(:skip_ordering => true, :forget_generated_options => true)
      @relation.count(:conditions => @ar_options[:conditions], :joins => @ar_options[:joins], :include => @ar_options[:include], :group => @ar_options[:group])
    end

    alias_method :size, :count

    def empty?  #:nodoc:
      self.count == 0
    end

    # with this variant we get even those values which do not appear in the resultset
    def distinct_values_for_column(column)  #:nodoc:
      res = column.model.find(:all, :select => "distinct #{column.name}", :order => "#{column.name} asc").collect{|ar|
        ar[column.name]
      }.reject{|e| e.blank?}.map{|i|[i,i]}
    end


    def distinct_values_for_column_in_resultset(messages)  #:nodoc:
      uniq_vals = Set.new

      resultset_without_paging_without_user_filters.each do |ar|
        v = ar.deep_send(*messages)
        uniq_vals << v unless v.nil?
      end
      return uniq_vals.to_a.map{|i|
        if i.is_a?(Array) && i.size == 2
          i
        elsif i.is_a?(Hash) && i.size == 1
          i.to_a.flatten
        else
          [i,i]
        end
      }.sort{|a,b| a[0]<=>b[0]}
    end

    def output_csv? #:nodoc:
      @status[:export] == 'csv'
    end

    def output_html? #:nodoc:
      @status[:export].blank?
    end

    def all_record_mode? #:nodoc:
      @status[:pp]
    end

    def dump_status #:nodoc:
      "   params: #{params[name].inspect}\n"  +
      "   status: #{@status.inspect}\n" +
      "   ar_options #{@ar_options.inspect}\n"
    end


    def selected_records #:nodoc:
      STDERR.puts "WiceGrid: Parameter :#{selected_records} is deprecated, use :#{all_pages_records} or :#{current_page_records} instead!"
      all_pages_records
    end

    # Returns the list of objects browsable through all pages with the current filters.
    # Should only be called after the +grid+ helper.
    def all_pages_records
      raise WiceGridException.new("all_pages_records can only be called only after the grid view helper") unless self.view_helper_finished
      resultset_without_paging_with_user_filters
    end

    # Returns the list of objects displayed on current page. Should only be called after the +grid+ helper.
    def current_page_records
      raise WiceGridException.new("current_page_records can only be called only after the grid view helper") unless self.view_helper_finished
      @resultset
    end



    protected

    def invoke_resultset_callback(callback, argument) #:nodoc:
      case callback
      when Proc
        callback.call(argument)
      when Symbol
        @controller.send(callback, argument)
      end
    end

    def invoke_resultset_callbacks #:nodoc:
      invoke_resultset_callback(@options[:with_paginated_resultset], @resultset)
      invoke_resultset_callback(@options[:with_resultset], lambda{self.send(:resultset_without_paging_with_user_filters)})
    end



    def add_custom_order_sql(fully_qualified_column_name) #:nodoc:
      custom_order = if @options[:custom_order].has_key?(fully_qualified_column_name)
        @options[:custom_order][fully_qualified_column_name]
      else
        if !@renderer.blank? and view_column = @renderer[fully_qualified_column_name]
          view_column.custom_order
        else
          nil
        end
      end

      if custom_order.blank?
        if ActiveRecord::ConnectionAdapters.const_defined?(:SQLite3Adapter) && ActiveRecord::Base.connection.is_a?(ActiveRecord::ConnectionAdapters::SQLite3Adapter)
          fully_qualified_column_name.strip.split('.').map{|chunk| ActiveRecord::Base.connection.quote_table_name(chunk)}.join('.')
        else
          ActiveRecord::Base.connection.quote_table_name(fully_qualified_column_name.strip)
        end
      else
        if custom_order.is_a? String
          custom_order.gsub(/\?/, fully_qualified_column_name)
        elsif custom_order.is_a? Proc
          custom_order.call(fully_qualified_column_name)
        else
          raise WiceGridArgumentError.new("invalid custom order #{custom_order.inspect}")
        end
      end
    end

    def complete_column_name(col_name)  #:nodoc:
      if col_name.index('.') # already has a table name
        col_name
      else # add the default table
        "#{@klass.table_name}.#{col_name}"
      end
    end

    def params  #:nodoc:
      @controller.params
    end

    def this_grid_params  #:nodoc:
      params[name]
    end


    def resultset_without_paging_without_user_filters  #:nodoc:
      form_ar_options
      @klass.unscoped do
        @relation.find(:all, :joins => @ar_options[:joins],
                          :include => @ar_options[:include],
                          :group => @ar_options[:group],
                          :conditions => @options[:conditions])
      end
    end

    def count_resultset_without_paging_without_user_filters  #:nodoc:
      form_ar_options
      @klass.unscoped do
        @relation.count(
          :joins => @ar_options[:joins],
          :include => @ar_options[:include],
          :group => @ar_options[:group],
          :conditions => @options[:conditions]
        )
      end
    end


    def resultset_without_paging_with_user_filters  #:nodoc:
      form_ar_options
      @klass.unscoped do
        @relation.find(:all, :joins      => @ar_options[:joins],
                          :include    => @ar_options[:include],
                          :group      => @ar_options[:group],
                          :conditions => @ar_options[:conditions],
                          :order      => @ar_options[:order])
      end
    end


    def load_query(query_id) #:nodoc:
      @query_store_model ||= Wice::get_query_store_model
      query = @query_store_model.find_by_id_and_grid_name(query_id, self.name)
      Wice::log("Query with id #{query_id} for grid '#{self.name}' not found!!!") if query.nil?
      query
    end


  end

  # routines called from WiceGridExtentionToActiveRecordColumn (ActiveRecord::ConnectionAdapters::Column) or FilterConditionsGenerator classes
  module GridTools   #:nodoc:
    class << self
      def special_value(str)   #:nodoc:
        str =~ /^\s*(not\s+)?null\s*$/i
      end

      # create a Time instance out of parameters
      def params_2_datetime(par)   #:nodoc:
        return nil if par.blank?
        params =  [par[:year], par[:month], par[:day], par[:hour], par[:minute]].collect{|v| v.blank? ? nil : v.to_i}
        begin
          Time.local(*params)
        rescue ArgumentError, TypeError
          nil
        end
      end

      # create a Date instance out of parameters
      def params_2_date(par)   #:nodoc:
        return nil if par.blank?
        params =  [par[:year], par[:month], par[:day]].collect{|v| v.blank? ? nil : v.to_i}
        begin
          Date.civil(*params)
        rescue ArgumentError, TypeError
          nil
        end
      end

    end
  end

  # to be mixed in into ActiveRecord::ConnectionAdapters::Column
  module WiceGridExtentionToActiveRecordColumn #:nodoc:

    attr_accessor :model

    def alias_or_table_name(table_alias)
      table_alias || self.model.table_name
    end

    def wg_initialize_request_parameters(all_filter_params, main_table, table_alias, custom_filter_active)  #:nodoc:
      @request_params = nil
      return if all_filter_params.nil?

      # if the parameter does not specify the table name we only allow columns in the default table to use these parameters
      if main_table && @request_params  = all_filter_params[self.name]
        current_parameter_name = self.name
      elsif @request_params = all_filter_params[alias_or_table_name(table_alias) + '.' + self.name]
        current_parameter_name = alias_or_table_name(table_alias) + '.' + self.name
      end

      # Preprocess incoming parameters for datetime, if what's coming in is
      # a datetime (with custom_filter it can be anything else, and not
      # the datetime hash {:fr => ..., :to => ...})
      if @request_params
        if (self.type == :datetime || self.type == :timestamp) && @request_params.is_a?(Hash)
          [:fr, :to].each do |sym|
            if @request_params[sym]
              if @request_params[sym].is_a?(String)
                @request_params[sym] = Wice::ConfigurationProvider.value_for(:DATETIME_PARSER).call(@request_params[sym])
              elsif @request_params[sym].is_a?(Hash)
                @request_params[sym] = Wice::GridTools.params_2_datetime(@request_params[sym])
              end
            end
          end

        end

        # Preprocess incoming parameters for date, if what's coming in is
        # a date (with custom_filter it can be anything else, and not
        # the date hash {:fr => ..., :to => ...})
        if self.type == :date && @request_params.is_a?(Hash)
          [:fr, :to].each do |sym|
            if @request_params[sym]
              if @request_params[sym].is_a?(String)
                @request_params[sym] = Wice::ConfigurationProvider.value_for(:DATE_PARSER).call(@request_params[sym])
              elsif @request_params[sym].is_a?(Hash)
                @request_params[sym] = ::Wice::GridTools.params_2_date(@request_params[sym])
              end
            end
          end
        end
      end

      return wg_generate_conditions(table_alias, custom_filter_active), current_parameter_name
    end

    def wg_generate_conditions(table_alias, custom_filter_active)  #:nodoc:
      return nil if @request_params.nil?

      if custom_filter_active
        return ::Wice::FilterConditionsGeneratorCustomFilter.new(self).generate_conditions(table_alias, @request_params)
      end

      column_type = self.type.to_s

      processor_class = ::Wice::FilterConditionsGenerator.handled_type[column_type]

      if processor_class
        return processor_class.new(self).generate_conditions(table_alias, @request_params)
      else
        Wice.log("No processor for database type #{column_type}!!!")
        nil
      end
    end

  end

  class FilterConditionsGenerator   #:nodoc:

    cattr_accessor :handled_type
    @@handled_type = HashWithIndifferentAccess.new

    def initialize(column)   #:nodoc:
      @column = column
    end
  end

  class FilterConditionsGeneratorCustomFilter < FilterConditionsGenerator #:nodoc:

    def generate_conditions(table_alias, opts)   #:nodoc:
      if opts.empty? || (opts.is_a?(Array) && opts.size == 1 && opts[0].blank?)
        return false
      end
      opts = (opts.kind_of?(Array) && opts.size == 1) ? opts[0] : opts

      if opts.kind_of?(Array)
        opts_with_special_values, normal_opts = opts.partition{|v| ::Wice::GridTools.special_value(v)}

        conditions_ar = if normal_opts.size > 0
          [" #{@column.alias_or_table_name(table_alias)}.#{@column.name} IN ( " + (['?'] * normal_opts.size).join(', ') + ' )'] + normal_opts
        else
          []
        end

        if opts_with_special_values.size > 0
          special_conditions = opts_with_special_values.collect{|v| " #{@column.alias_or_table_name(table_alias)}.#{@column.name} is " + v}.join(' or ')
          if conditions_ar.size > 0
            conditions_ar[0] = " (#{conditions_ar[0]} or #{special_conditions} ) "
          else
            conditions_ar = " ( #{special_conditions} ) "
          end
        end
        conditions_ar
      else
        if ::Wice::GridTools.special_value(opts)
          " #{@column.alias_or_table_name(table_alias)}.#{@column.name} is " + opts
        else
          [" #{@column.alias_or_table_name(table_alias)}.#{@column.name} = ?", opts]
        end
      end
    end

  end

  class FilterConditionsGeneratorBoolean < FilterConditionsGenerator  #:nodoc:
    @@handled_type[:boolean] = self

    def  generate_conditions(table_alias, opts)   #:nodoc:
      unless (opts.kind_of?(Array) && opts.size == 1)
        Wice.log "invalid parameters for the grid boolean filter - must be an one item array: #{opts.inspect}"
        return false
      end
      opts = opts[0]
      if opts == 'f'
        [" (#{@column.alias_or_table_name(table_alias)}.#{@column.name} = ? or #{@column.alias_or_table_name(table_alias)}.#{@column.name} is null) ", false]
      elsif opts == 't'
        [" #{@column.alias_or_table_name(table_alias)}.#{@column.name} = ?", true]
      else
        nil
      end
    end
  end

  class FilterConditionsGeneratorString < FilterConditionsGenerator  #:nodoc:
    @@handled_type[:string] = self
    @@handled_type[:text]   = self

    def generate_conditions(table_alias, opts)   #:nodoc:
      if opts.kind_of? String
        string_fragment = opts
        negation = ''
      elsif (opts.kind_of? Hash) && opts.has_key?(:v)
        string_fragment = opts[:v]
        negation = opts[:n] == '1' ? 'NOT' : ''
      else
        Wice.log "invalid parameters for the grid string filter - must be a string: #{opts.inspect} or a Hash with keys :v and :n"
        return false
      end
      if string_fragment.empty?
        return false
      end
      [" #{negation}  #{@column.alias_or_table_name(table_alias)}.#{@column.name} #{::Wice.get_string_matching_operators(@column.model)} ?",
          '%' + string_fragment + '%']
    end

  end

  class FilterConditionsGeneratorInteger < FilterConditionsGenerator  #:nodoc:
    @@handled_type[:integer] = self
    @@handled_type[:float]   = self
    @@handled_type[:decimal] = self

    def  generate_conditions(table_alias, opts)   #:nodoc:
      unless opts.kind_of? Hash
        Wice.log "invalid parameters for the grid integer filter - must be a hash"
        return false
      end
      conditions = [[]]
      if opts[:fr]
        if opts[:fr] =~ /\d/
          conditions[0] << " #{@column.alias_or_table_name(table_alias)}.#{@column.name} >= ? "
          conditions << opts[:fr]
        else
          opts.delete(:fr)
        end
      end

      if opts[:to]
        if opts[:to] =~ /\d/
          conditions[0] << " #{@column.alias_or_table_name(table_alias)}.#{@column.name} <= ? "
          conditions << opts[:to]
        else
          opts.delete(:to)
        end
      end

      if conditions.size == 1
        return false
      end

      conditions[0] = conditions[0].join(' and ')

      return conditions
    end
  end

  class FilterConditionsGeneratorDate < FilterConditionsGenerator  #:nodoc:
    @@handled_type[:date]      = self
    @@handled_type[:datetime]  = self
    @@handled_type[:timestamp] = self

    def generate_conditions(table_alias, opts)   #:nodoc:
      conditions = [[]]
      if opts[:fr]
        conditions[0] << " #{@column.alias_or_table_name(table_alias)}.#{@column.name} >= ? "
        conditions << opts[:fr]
      end

      if opts[:to]
        conditions[0] << " #{@column.alias_or_table_name(table_alias)}.#{@column.name} <= ? "
        conditions << opts[:to]
      end

      return false if conditions.size == 1

      conditions[0] = conditions[0].join(' and ')
      return conditions
    end
  end

end
