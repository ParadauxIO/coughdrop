import RSVP from 'rsvp';
import DS from 'ember-data';
import CoughDrop from '../app';
import i18n from '../utils/i18n';
import persistence from '../utils/persistence';
import app_state from '../utils/app_state';
import { observer } from '@ember/object';
import { computed } from '@ember/object';

CoughDrop.Image = DS.Model.extend({
  didLoad: function() {
    this.checkForDataURL().then(null, function() { });
    this.set('app_state', app_state);
    this.clean_license();
  },
  url: DS.attr('string'),
  fallback: DS.attr('boolean'),
  content_type: DS.attr('string'),
  width: DS.attr('number'),
  height: DS.attr('number'),
  hc: DS.attr('boolean'),
  pending: DS.attr('boolean'),
  avatar: DS.attr('boolean'),
  badge: DS.attr('boolean'),
  protected: DS.attr('boolean'),
  protected_source: DS.attr('string'),
  suggestion: DS.attr('string'),
  external_id: DS.attr('string'),
  search_term: DS.attr('string'),
  button_label: DS.attr('string'),
  source_url: DS.attr('string'),
  license: DS.attr('raw'),
  permissions: DS.attr('raw'),
  file: DS.attr('boolean'),
  filename: computed('url', function() {
    var url = this.get('url') || '';
    if(url.match(/^data/)) {
      return i18n.t('embedded_image', "embedded image");
    } else {
      var paths = url.split(/\?/)[0].split(/\//);
      var name = paths[paths.length - 1];
      if(!name.match(/\.(png|gif|jpg|jpeg|svg)$/)) {
        name = null;
      }
      return decodeURIComponent(name || 'image');
    }
  }),
  skinned: computed('url', function() {
    return CoughDrop.Board.is_skinned_url(this.get('url'));
  }),
  clean_license: function() {
    var _this = this;
    ['copyright_notice', 'source', 'author'].forEach(function(key) {
      if(_this.get('license.' + key + '_link')) {
        _this.set('license.' + key + '_url', _this.get('license.' + key + '_url') || _this.get('license.' + key + '_link'));
      }
      if(_this.get('license.' + key + '_link')) {
        _this.set('license.' + key + '_link', _this.get('license.' + key + '_link') || _this.get('license.' + key + '_url'));
      }
    });
  },
  license_string: computed('license', 'license.type', function() {
    var license = this.get('license');
    if(!license || !license.type) {
      return i18n.t('unknown_license', "Unknown. Assume all rights reserved");
    } else if(license.type == 'private') {
      return i18n.t('all_rights_reserved', "All rights reserved");
    } else {
      return license.type;
    }
  }),
  author_url_or_email: computed('license', 'license.author_url', 'license.author_email', function() {
    var license = this.get('license') || {};
    if(license.author_url) {
      return license.author_url;
    } else if(license.author_email) {
      return license.author_email;
    } else {
      return null;
    }
  }),
  check_for_editable_license: observer('license', 'id', 'permissions.edit', function() {
    if(this.get('license') && this.get('id') && !this.get('permissions.edit')) {
      this.set('license.uneditable', true);
    }
  }),
  personalized_url: computed('url', 'app_state.currentUser.user_token', 'app_state.referenced_user.preferences.skin', function() {
    CoughDrop.Image.unskins = CoughDrop.Image.unskins || {};
    return CoughDrop.Image.personalize_url(this.get('url'), this.get('app_state.currentUser.user_token'), this.get('app_state.referenced_user.preferences.skin'), CoughDrop.Image.unskins[this.get('id')]);
  }),
  best_url: computed('personalized_url', 'data_url', function() {
    return this.get('data_url') || this.get('personalized_url') || "";
  }),
  checkForDataURL: function() {
    this.set('checked_for_data_url', true);
    var _this = this;
    if(!this.get('data_url') && CoughDrop.remote_url(this.get('personalized_url'))) {
      return persistence.find_url(this.get('personalized_url'), 'image').then(function(data_uri) {
        _this.set('data_url', data_uri);
        if(data_uri && data_uri.match(/^file/)) {
          var img = new Image();
          img.src = data_uri;
        }
        return _this;
      });
    } else if(this.get('url') && this.get('url').match(/^data/)) {
      return RSVP.resolve(this);
    }
    return RSVP.reject('no image data url');
  },
  checkForDataURLOnChange: observer('personalized_url', function() {
    this.checkForDataURL().then(null, function() { });
  })
});

CoughDrop.Image.reopenClass({
  personalize_url: function(url, token, skin, unskin) {
    url = url || '';
    var res = url
    if(url.match(/api\/v1\//) && url.match(/lessonpix/) && token) {
      res = url + "?user_token=" + token;
    }
    if(skin && skin != 'default') {
      var which_skin = CoughDrop.Board.which_skinner(skin);
      res = CoughDrop.Board.skinned_url(url, which_skin, unskin);
    }
    return res;
  },
  mimic_server_processing: function(record, hash) {
    if(record.get('data_url')) {
      hash.image.url = record.get('data_url');
      hash.image.data_url = hash.image.url;
    }
    return hash;
  }
});

export default CoughDrop.Image;
