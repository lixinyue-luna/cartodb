var _ = require('underscore');

function buildSwatch (color, name) {
  if (_.isString(color)) {
    color = {
      fixed: color,
      opacity: 1
    };
  }

  return {
    fill: {
      color: color
    },
    title: name
  };
}

function _unquote (c) {
  return c && c.replace && c.replace(/^"(.+(?="$))"$/, '$1');
}

function simpleColor (color) {
  return [buildSwatch(color, '')];
}

function collectionColor (color) {
  var range = color.range.length;
  return _.range(range).map(function (v, index) {
    // if style attribute is number there is no domain (choropleth)
    return buildSwatch(color.range[index], color.domain && _unquote(color.domain[index]) || '');
  });
}

module.exports = {
  buildSwatch: buildSwatch,
  getCategories: function (color) {
    if (color.fixed !== undefined) {
      return simpleColor(color);
    } else if (color.attribute) {
      return collectionColor(color);
    }
  },

  unquoteColor: _unquote,
  getBubbles: function (color) {
    return _.omit(_.first(this.getCategories(color)), 'title').fill;
  }
};
