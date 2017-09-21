require 'active_record' unless defined? ActiveRecord

module Paranoia
  def self.included(klazz)
    klazz.extend Query
    klazz.extend Callbacks

  end

  # Given an association derive appropriate where clause to find the targets
  def self.__derive_fitler_expression(association, context)
    pk = association.primary_key_column.name.to_sym
    fk = association.foreign_key

    # If it is a belongs to association then context should have the foreign_key

    if association.belongs_to?
      {pk => context.send(fk)}
    else
        # Else use the type if it is polymorphic and target has the foreign_key
        is_polymorphic = !association.options[:as].blank?
        if is_polymorphic
          t = association.type
          {t => context.class.name.to_s, fk => context.id}
        else
          {fk => context.id}
        end
    end
  end

  # Check that the model belongs_to to association and foreign_key is set
  def self.__is_associated?(association, context)
    if association.belongs_to?
      fk = association.foreign_key
      !context.send(fk).nil?
    else
      true
    end
  end

  module Query
    def paranoid?
      true
    end


    def with_deleted
      scoped.tap { |x| x.default_scoped = false }
    end

    def only_deleted
      with_deleted.where("#{self.table_name}.#{paranoia_column} IS NOT NULL")
    end
    alias :deleted :only_deleted

    def restore(id, opts = {})
      if id.is_a?(Array)
        id.map { |one_id| restore(one_id, opts) }
      else
        only_deleted.find(id).restore!(opts)
      end
    end
  end

  module Callbacks
    def self.extended(klazz)
      klazz.define_callbacks :restore

      klazz.define_singleton_method("before_restore") do |*args, &block|
        set_callback(:restore, :before, *args, &block)
      end

      klazz.define_singleton_method("around_restore") do |*args, &block|
        set_callback(:restore, :around, *args, &block)
      end

      klazz.define_singleton_method("after_restore") do |*args, &block|
        set_callback(:restore, :after, *args, &block)
      end
    end
  end

  def destroy
    callbacks_result = run_callbacks(:destroy) { touch_paranoia_column(true) }
    callbacks_result ? self : false
  end

  def delete
    return if new_record?
    touch_paranoia_column(false)
  end

  def restore!(opts = {})
    __instance = self
    ActiveRecord::Base.transaction do
      run_callbacks(:restore) do
        update_column paranoia_column, nil
        restore_associated_records unless opts[:recursive] == false
      end
    end
  end
  alias :restore :restore!

  def destroyed?
    !!send(paranoia_column)
  end

  alias :deleted? :destroyed?

  private

  # touch paranoia column.
  # insert time to paranoia column.
  # @param with_transaction [Boolean] exec with ActiveRecord Transactions.
  def touch_paranoia_column(with_transaction=false)
    # This method is (potentially) called from really_destroy
    # The object the method is being called on may be frozen
    # Let's not touch it if it's frozen.
    unless self.frozen?
      if with_transaction
        with_transaction_returning_status { touch(paranoia_column) }
      else
        touch(paranoia_column)
      end
    end
  end



  # restore associated records that have been soft deleted when
  # we called #destroy
  def restore_associated_records
    destroyed_associations = self.class.reflect_on_all_associations.select do |association|
      association.options[:dependent] == :destroy
    end

    ___selfishness = self

    destroyed_associations.each do |association|
      next unless Paranoia.__is_associated?(association, ___selfishness)
      entity = association.klass
      find_expression = Paranoia.__derive_fitler_expression(association, ___selfishness)
      if association.collection?
        item = entity.only_deleted.where(find_expression).each {|record| restore_child(record)}
      else
        item = entity.only_deleted.where(find_expression).first
        restore_child(item) unless item.nil?
      end

    end
  end

  def restore_child(entity)
    if entity.respond_to?('paranoid?')

      entity.restore(:recursive => true)
    end
  end
end

class ActiveRecord::Base
  def self.acts_as_paranoid(options={})
    alias :really_destroyed? :destroyed?
    alias :ar_destroy :destroy
    alias :destroy! :ar_destroy
    alias :delete! :delete
    def really_destroy!
      dependent_reflections = self.reflections.select do |name, reflection|
        reflection.options[:dependent] == :destroy
      end
      ___selfishness = self
      if dependent_reflections.any?
        dependent_reflections.each do |name, association|
          if association.collection?
            associated_records = self.send(name)
            # Paranoid models will have this method, non-paranoid models will not
            associated_records = associated_records.with_deleted if associated_records.respond_to?(:with_deleted)
            associated_records.each(&:really_destroy!)
          else
            next unless Paranoia.__is_associated?(association, ___selfishness)
            entity = association.klass
            find_expression = Paranoia.__derive_fitler_expression(association, ___selfishness)
            item = entity.with_deleted.where(find_expression).first
            item.really_destroy! unless item.nil?
          end
        end
      end
      destroy!
    end

    include Paranoia
    class_attribute :paranoia_column

    self.paranoia_column = options[:column] || :deleted_at
    default_scope { where(self.quoted_table_name + ".#{paranoia_column} IS NULL") }

    before_restore {
      self.class.notify_observers(:before_restore, self) if self.class.respond_to?(:notify_observers)
    }
    after_restore {
      self.class.notify_observers(:after_restore, self) if self.class.respond_to?(:notify_observers)
    }
  end

  def self.paranoid?
    false
  end

  def paranoid?
    self.class.paranoid?
  end

  # Override the persisted method to allow for the paranoia gem.
  # If a paranoid record is selected, then we only want to check
  # if it's a new record, not if it is "destroyed".
  def persisted?
    paranoid? ? !new_record? : super
  end

  private

  def paranoia_column
    self.class.paranoia_column
  end
end


require 'paranoia/rspec' if defined? RSpec

module ActiveRecord
  module Validations
    class UniquenessValidator < ActiveModel::EachValidator
      protected
      def build_relation_with_paranoia(klass, table, attribute, value)
        relation = build_relation_without_paranoia(klass, table, attribute, value)
        relation.and(klass.arel_table[klass.paranoia_column].eq(nil))
      end
      alias_method_chain :build_relation, :paranoia
    end
  end
end
