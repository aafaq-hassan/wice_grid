# encoding: UTF-8
module Wice

  class ViewColumnDatetime < ViewColumn #:nodoc:
    include ActionView::Helpers::DateHelper
    include Wice::JsCalendarHelpers


    # name_and_id_from_options in Rails Date helper does not substitute '.' with '_'
    # like all other simpler form helpers do. Thus, overriding it here.
    def name_and_id_from_options(options, type)  #:nodoc:
      options[:name] = (options[:prefix] || DEFAULT_PREFIX) + (options[:discard_type] ? '' : "[#{type}]")
      options[:id] = options[:name].gsub(/([\[\(])|(\]\[)/, '_').gsub(/[\]\)]/, '').gsub(/\./, '_').gsub(/_+/, '_')
    end

    @@datetime_chunk_names = %w(year month day hour minute)

    def prepare_for_standard_filter #:nodoc:
      x = lambda{|sym|
        @@datetime_chunk_names.collect{|datetime_chunk_name|
          triple = form_parameter_name_id_and_query(sym => {datetime_chunk_name => ''})
          [triple[0], triple[3]]
        }
      }

      @queris_ids = x.call(:fr) + x.call(:to)

      _, _, @name1, _ = form_parameter_name_id_and_query({:fr => ''})
      _, _, @name2, _ = form_parameter_name_id_and_query({:to => ''})
    end


    def prepare_for_calendar_filter #:nodoc:
      query, _, @name1, @dom_id = form_parameter_name_id_and_query(:fr => '')
      query2, _, @name2, @dom_id2 = form_parameter_name_id_and_query(:to => '')

      @queris_ids = [[query, @dom_id], [query2, @dom_id2] ]
    end


    def render_standard_filter_internal(params) #:nodoc:
      '<div class="date-filter">' +
      select_datetime(params[:fr], {:include_blank => true, :prefix => @name1}) + '<br/>' +
      select_datetime(params[:to], {:include_blank => true, :prefix => @name2}) +
      '</div>'
    end

    def render_calendar_filter_internal(params) #:nodoc:

      html1 = date_calendar_jquery(
        params[:fr], NlMessage['date_selector_tooltip_from'], :prefix => @name1, :fire_event => auto_reload, :grid_name => self.grid.name)

      html2 = date_calendar_jquery(
        params[:to], NlMessage['date_selector_tooltip_to'],   :prefix => @name2, :fire_event => auto_reload, :grid_name => self.grid.name)

      %!<div class="date-filter">#{html1}<br/>#{html2}</div>!
    end


    def render_filter_internal(params) #:nodoc:
      if helper_style == :standard
        prepare_for_standard_filter
        render_standard_filter_internal(params)
      else
        prepare_for_calendar_filter
        render_calendar_filter_internal(params)
      end
    end


    def yield_declaration_of_column_filter #:nodoc:
      {
        :templates => @queris_ids.collect{|tuple|  tuple[0] },
        :ids       => @queris_ids.collect{|tuple|  tuple[1] }
      }
    end


    def has_auto_reloading_calendar? #:nodoc:
      auto_reload && helper_style == :calendar
    end

  end

end