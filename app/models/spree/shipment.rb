# frozen_string_literal: true

require 'ostruct'

module Spree
  class Shipment < ActiveRecord::Base
    belongs_to :order, class_name: 'Spree::Order'
    belongs_to :address, class_name: 'Spree::Address'
    belongs_to :stock_location, class_name: 'Spree::StockLocation'

    has_many :shipping_rates, dependent: :delete_all
    has_many :shipping_methods, through: :shipping_rates
    has_many :state_changes, as: :stateful
    has_many :inventory_units, dependent: :delete_all
    has_one :adjustment, as: :source, dependent: :destroy

    before_create :generate_shipment_number
    after_save :ensure_correct_adjustment, :update_order

    attr_accessor :special_instructions

    accepts_nested_attributes_for :address
    accepts_nested_attributes_for :inventory_units

    make_permalink field: :number

    scope :shipped, -> { with_state('shipped') }
    scope :ready,   -> { with_state('ready') }
    scope :pending, -> { with_state('pending') }
    scope :with_state, ->(*s) { where(state: s) }
    scope :trackable, -> { where("tracking IS NOT NULL AND tracking != ''") }

    # Shipment state machine
    # See http://github.com/pluginaweek/state_machine/tree/master for details
    state_machine initial: :pending, use_transactions: false do
      event :ready do
        transition from: :pending, to: :ready, if: lambda { |shipment|
          # Fix for #2040
          shipment.determine_state(shipment.order) == 'ready'
        }
      end

      event :pend do
        transition from: :ready, to: :pending
      end

      event :ship do
        transition from: :ready, to: :shipped
      end
      after_transition to: :shipped, do: :after_ship

      event :cancel do
        transition to: :canceled, from: [:pending, :ready]
      end
      after_transition to: :canceled, do: :after_cancel

      event :resume do
        transition from: :canceled, to: :ready, if: lambda { |shipment|
          shipment.determine_state(shipment.order) == :ready
        }
        transition from: :canceled, to: :pending, if: lambda { |shipment|
          shipment.determine_state(shipment.order) == :ready
        }
        transition from: :canceled, to: :pending
      end
      after_transition from: :canceled, to: [:pending, :ready], do: :after_resume
    end

    def to_param
      generate_shipment_number unless number
      number.to_s.to_url.upcase
    end

    def backordered?
      inventory_units.any?(&:backordered?)
    end

    def shipped=(value)
      return unless value == '1' && shipped_at.nil?

      self.shipped_at = Time.zone.now
    end

    def shipping_method
      selected_shipping_rate.try(:shipping_method) || shipping_rates.first.try(:shipping_method)
    end

    def add_shipping_method(shipping_method, selected = false)
      shipping_rates.create(shipping_method: shipping_method, selected: selected)
    end

    def selected_shipping_rate
      shipping_rates.find_by(selected: true)
    end

    def selected_shipping_rate_id
      selected_shipping_rate.try(:id)
    end

    def selected_shipping_rate_id=(id)
      shipping_rates.update_all(selected: false)
      shipping_rates.update(id, selected: true)
      save!
    end

    def refresh_rates
      return shipping_rates if shipped?

      # The call to Stock::Estimator below will replace the current shipping_method
      original_shipping_method_id = shipping_method.try(:id)
      self.shipping_rates = OrderManagement::Stock::Estimator.new(order).shipping_rates(to_package)

      keep_original_shipping_method_selection(original_shipping_method_id)

      shipping_rates
    end

    def keep_original_shipping_method_selection(original_shipping_method_id)
      return if shipping_method&.id == original_shipping_method_id

      rate_for_original_shipping_method = find_shipping_rate_for(original_shipping_method_id)
      if rate_for_original_shipping_method.present?
        self.selected_shipping_rate_id = rate_for_original_shipping_method.id
      else
        # If there's no original ship method to keep, or if it cannot be found on the ship rates
        #   But there's a new ship method selected (first if clause in this method)
        #   We need to save the shipment so that callbacks are triggered
        save!
      end
    end

    def find_shipping_rate_for(shipping_method_id)
      return unless shipping_method_id

      shipping_rates.detect { |rate|
        rate.shipping_method_id == shipping_method_id
      }
    end

    def currency
      order ? order.currency : Spree::Config[:currency]
    end

    # The adjustment amount associated with this shipment (if any)
    #   Returns only the first adjustment to match the shipment
    #   There should never really be more than one.
    def cost
      adjustment ? adjustment.amount : 0
    end

    alias_method :amount, :cost

    def display_cost
      Spree::Money.new(cost, currency: currency)
    end

    alias_method :display_amount, :display_cost

    def item_cost
      line_items.map(&:amount).sum
    end

    def display_item_cost
      Spree::Money.new(item_cost, currency: currency)
    end

    def total_cost
      cost + item_cost
    end

    def display_total_cost
      Spree::Money.new(total_cost, currency: currency)
    end

    def editable_by?(_user)
      !shipped?
    end

    def manifest
      inventory_units.group_by(&:variant).map do |variant, units|
        states = {}
        units.group_by(&:state).each { |state, iu| states[state] = iu.count }
        scoper.scope(variant)
        OpenStruct.new(variant: variant, quantity: units.length, states: states)
      end
    end

    def scoper
      @scoper ||= OpenFoodNetwork::ScopeVariantToHub.new(order.distributor)
    end

    def line_items
      if order.complete?
        order.line_items.select { |li| inventory_units.pluck(:variant_id).include?(li.variant_id) }
      else
        order.line_items
      end
    end

    def finalize!
      InventoryUnit.finalize_units!(inventory_units)
      manifest.each { |item| manifest_unstock(item) }
    end

    def after_cancel
      manifest.each { |item| manifest_restock(item) }
    end

    def after_resume
      manifest.each { |item| manifest_unstock(item) }
    end

    # Updates various aspects of the Shipment while bypassing any callbacks.
    #   Note that this method takes an explicit reference to the Order object.
    #   This is necessary because the association actually has a stale (and unsaved) copy of the
    #     Order and so it will not yield the correct results.
    def update!(order)
      old_state = state
      new_state = determine_state(order)
      update_column :state, new_state
      after_ship if new_state == 'shipped' && old_state != 'shipped'
    end

    # Determines the appropriate +state+ according to the following logic:
    #
    # pending    unless order is complete and +order.payment_state+ is +paid+
    # shipped    if already shipped (ie. does not change the state)
    # ready      all other cases
    def determine_state(order)
      return 'canceled' if order.canceled?
      return 'pending' unless order.can_ship?
      return 'pending' if inventory_units.any?(&:backordered?)
      return 'shipped' if state == 'shipped'

      order.paid? ? 'ready' : 'pending'
    end

    def tracking_url
      @tracking_url ||= shipping_method.build_tracking_url(tracking)
    end

    def include?(variant)
      inventory_units_for(variant).present?
    end

    def inventory_units_for(variant)
      inventory_units.group_by(&:variant_id)[variant.id] || []
    end

    def to_package
      package = OrderManagement::Stock::Package.new(stock_location, order)
      inventory_units.includes(:variant).each do |inventory_unit|
        package.add inventory_unit.variant, 1, inventory_unit.state_name
      end
      package
    end

    def set_up_inventory(state, variant, order)
      inventory_units.create(variant_id: variant.id, state: state, order_id: order.id)
    end

    def ensure_correct_adjustment
      if adjustment
        adjustment.originator = shipping_method
        adjustment.label = shipping_method.adjustment_label
        adjustment.amount = selected_shipping_rate.cost if adjustment.open?
        adjustment.save!
        adjustment.reload
      elsif selected_shipping_rate_id
        shipping_method.create_adjustment(shipping_method.adjustment_label,
                                          order,
                                          self,
                                          true,
                                          "open")
        reload # ensure adjustment is present on later saves
      end

      update_adjustment_included_tax if adjustment
    end

    private

    def manifest_unstock(item)
      stock_location.unstock item.variant, item.quantity, self
    end

    def manifest_restock(item)
      stock_location.restock item.variant, item.quantity, self
    end

    def generate_shipment_number
      return number if number.present?

      record = true
      while record
        random = "H#{Array.new(11) { rand(9) }.join}"
        record = self.class.find_by(number: random)
      end
      self.number = random
    end

    def description_for_shipping_charge
      "#{Spree.t(:shipping)} (#{shipping_method.name})"
    end

    def validate_shipping_method
      return if shipping_method.nil?

      return if shipping_method.include?(address)

      errors.add :shipping_method, Spree.t(:is_not_available_to_shipment_address)
    end

    def after_ship
      inventory_units.each(&:ship!)
      adjustment.finalize!
      send_shipped_email
      touch :shipped_at
    end

    def send_shipped_email
      ShipmentMailer.shipped_email(id).deliver_now
    end

    def update_adjustment_included_tax
      if Config.shipment_inc_vat && (order.distributor.nil? || order.distributor.charges_sales_tax)
        adjustment.set_included_tax! Config.shipping_tax_rate
      else
        adjustment.set_included_tax! 0
      end
    end

    def update_order
      order.update!
    end
  end
end
