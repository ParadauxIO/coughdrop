import modal from '../utils/modal';
import app_state from '../utils/app_state';
import i18n from '../utils/i18n';
import { observer } from '@ember/object';
import { computed } from '@ember/object';

export default modal.ModalController.extend({
  opening: function() {
    this.set('model.jump_home', this.get('model.stay') !== true);
    this.set('model.keep_as_self', this.get('model.modeling') || app_state.get('referenced_speak_mode_user') != null);
    if(this.get('model.modeling') == 'ask') {
      this.set('model.keep_as_self', true);
    }
    this.set('has_supervisees', app_state.get('sessionUser.supervisees.length') > 0);
    this.set('currently_selected_id', null);
  },
  self_currently_selected: computed('app_state.currentUser.id', function() {
    return app_state.get('currentUser.id') && app_state.get('currentUser.id') == app_state.get('sessionUser.id');
  }),
  select_on_change: observer('currently_selected_id', function() {
    if(this.get('currently_selected_id')) {
      this.send('select', this.get('currently_selected_id'));
    }
  }),
  modeling_choice: computed('model.modeling', function() {
    return this.get('model.modeling') !== undefined && this.get('model.modeling') != 'ask';
  }),
  actions: {
    select: function(board_for_user_id) {
      var jump_home = this.get('model.jump_home');
      var keep_as_self = this.get('model.keep_as_self');
      modal.close();
      if(this.get('model.route')) {
        var _this = this;
        this.store.findRecord('user', board_for_user_id).then(function(u) {
          _this.transitionToRoute(_this.get('model.route'), u.get('user_name'));
        }, function(err) {
          modal.close();
          modal.error(i18n.t('error_loading_user_details', "There was an unexpected error loading the user's details"));
        });
      } else if(this.get('model.modal')) {
        var _this = this;
        this.store.findRecord('user', board_for_user_id).then(function(u) {
          modal.open(_this.get('modal.modal'), {user: u});
        }, function(err) {
          modal.close();
          modal.error(i18n.t('error_loading_user_details', "There was an unexpected error loading the user's details"));
        });
      } else if(this.get('model.eval')) {
        app_state.set_speak_mode_user(board_for_user_id, false, false, 'obf/eval');
      } else {
        app_state.set_speak_mode_user(board_for_user_id, jump_home, keep_as_self);
      }
    },
    set_attribute(attr, val) {
      this.set('model.' + attr, val);
    }
  }
});
