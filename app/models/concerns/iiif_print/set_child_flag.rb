# frozen_string_literal: true

module RDF
  class CustomIsChildTerm < Vocabulary('http://id.loc.gov/vocabulary/identifiers/')
    property 'is_child'
  end
end

module IiifPrint
  module SetChildFlag
    extend ActiveSupport::Concern
    included do
      after_save :set_children
      property :is_child,
              predicate: ::RDF::CustomIsChildTerm.is_child,
              multiple: false do |index|
                index.as :stored_searchable
              end
    end

    def set_children
      ordered_works.each do |child_work|
        child_work.update(is_child: true) unless child_work.is_child
      end
    end
  end
end
