# encoding: UTF-8
module Wice

  class ActionViewColumn < ViewColumn #:nodoc:
    def initialize(grid_obj, html, param_name, select_all_buttons, object_property, 
        view, show_single_select_all_checkbox)  #:nodoc:
      @view = view
      @select_all_buttons   = select_all_buttons
      self.grid             = grid_obj
      self.html             = html
      Wice::WgHash.add_or_append_class_value!(self.html, 'sel')
      grid_name             = self.grid.name
      @param_name           = param_name
      count = -1
      self.show_single_select_all_checkbox = show_single_select_all_checkbox

      @cell_rendering_block = lambda do |object, params|
        selected = if params[grid_name] && params[grid_name][param_name] &&
                      params[grid_name][param_name].index(object.send(object_property).to_s)
          true
        else
          false
        end

        count += 1
        check_box_tag("#{grid_name}[#{param_name}][]", object.send(object_property), 
          selected, :id => "#{html[:id]}#{count}")
      end
    end

    def in_html  #:nodoc:
      true
    end

    def capable_of_hosting_filter_related_icons?  #:nodoc:
      false
    end

    def name  #:nodoc:
      return '' unless @select_all_buttons

      if(self.show_single_select_all_checkbox)
        html = content_tag(:span, check_box_tag("select_all", nil, false, 
            :class => 'clickable select_all', :id => 'select_all_checkbox'),
          :class => 'clickable select_all', :title => NlMessage['select_all'], 
          :id => 'select_all_span', 
          :onclick => 'javascript: $(this).hide(); $("#select_all_checkbox").prop('checked',false); $("#deselect_all_span").show();') + '' +
          content_tag(:span, check_box_tag("deselect_all", nil, true, 
            :class => 'clickable deselect_all', :id => 'deselect_all_checkbox'),
          :class => 'clickable deselect_all', :title => NlMessage['deselect_all'], 
          :id => 'deselect_all_span', :style => 'display:none', 
          :onclick => 'javascript:  $(this).hide(); $("#deselect_all_checkbox").prop('checked', true); $("#select_all_span").show();')
      else
        html = content_tag(:span, image_tag(Defaults::TICK_ALL_ICON, :alt => NlMessage['select_all']),
          :class => 'clickable select_all', :title => NlMessage['select_all']) + ' ' +
          content_tag(:span, image_tag(Defaults::UNTICK_ALL_ICON, :alt => NlMessage['deselect_all']),
          :class => 'clickable deselect_all', :title => NlMessage['deselect_all'])
      end

      html
    end

  end
end
