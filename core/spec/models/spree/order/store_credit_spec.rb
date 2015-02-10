require 'spec_helper'

shared_examples "check total store credit from payments" do
  context "with valid payments" do
    let(:order)           { payment.order }
    let!(:payment)        { create(:store_credit_payment) }
    let!(:second_payment) { create(:store_credit_payment, order: order) }

    subject { order }

    it "returns the sum of the payment amounts" do
      expect(subject.total_applicable_store_credit).to eq (payment.amount + second_payment.amount)
    end
  end

  context "without valid payments" do
    let(:order) { create(:order) }

    subject { order }

    it "returns 0" do
      expect(subject.total_applicable_store_credit).to be_zero
    end
  end
end

describe "Order" do

  describe "#add_store_credit_payments" do
    let(:order_total) { 500.00 }

    before { create(:store_credit_payment_method) }

    subject { order.add_store_credit_payments }

    context "there is no store credit" do
      let(:order)       { create(:store_credits_order_without_user, total: order_total) }

      context "there is a credit card payment" do
        let!(:cc_payment) { create(:payment, order: order) }

        before do
          # callbacks recalculate total based on line items
          # this ensures the total is what we expect
          order.update_column(:total, order_total)
          subject
          order.reload
        end

        it "charges the outstanding balance to the credit card" do
          expect(order.payments.count).to eq 1
          expect(order.payments.first.source).to be_a(Spree::CreditCard)
          expect(order.payments.first.amount).to eq order_total
        end
      end

      context "there are no other payments" do
        it "adds an error to the model" do
          expect(subject).to be false
          expect(order.errors.full_messages).to include(Spree.t("store_credit.errors.unable_to_fund"))
        end
      end

      context "there is a payment of an unknown type" do
        let!(:check_payment) { create(:check_payment, order: order) }

        it "raises an error" do
          expect { subject }.to raise_error
        end
      end
    end

    context "there is enough store credit to pay for the entire order" do
      let(:store_credit) { create(:store_credit, amount: order_total) }
      let(:order)        { create(:order, user: store_credit.user, total: order_total) }

      context "there are no other payments" do
        before do
          subject
          order.reload
        end

        it "creates a store credit payment for the full amount" do
          expect(order.payments.count).to eq 1
          expect(order.payments.first).to be_store_credit
          expect(order.payments.first.amount).to eq order_total
        end
      end

      context "there is a credit card payment" do
        let!(:cc_payment) { create(:payment, order: order) }

        before { subject }

        it "should invalidate the credit card payment" do
          expect(cc_payment.reload.state).to == 'invalid'
        end
      end

      context "there is a payment of an unknown type" do
        let!(:check_payment) { create(:check_payment, order: order) }

        it "raises an error" do
          expect { subject }.to raise_error
        end
      end
    end

    context "the available store credit is not enough to pay for the entire order" do
      let(:expected_cc_total)  { 100.0 }
      let(:store_credit_total) { order_total - expected_cc_total }
      let(:store_credit)       { create(:store_credit, amount: store_credit_total) }
      let(:order)              { create(:order, user: store_credit.user, total: order_total) }


      context "there are no other payments" do
        it "adds an error to the model" do
          expect(subject).to be false
          expect(order.errors.full_messages).to include(Spree.t("store_credit.errors.unable_to_fund"))
        end
      end

      context "there is a credit card payment" do
        let!(:cc_payment) { create(:payment, order: order) }

        before do
          # callbacks recalculate total based on line items
          # this ensures the total is what we expect
          order.update_column(:total, order_total)
          subject
          order.reload
        end

        it "charges the outstanding balance to the credit card" do
          expect(order.payments.count).to eq 2
          expect(order.payments.first.source).to be_a(Spree::CreditCard)
          expect(order.payments.first.amount).to eq expected_cc_total
        end
      end

      context "there is a payment of an unknown type" do
        let!(:check_payment) { create(:check_payment, order: order) }

        it "raises an error" do
          expect { subject }.to raise_error
        end
      end
    end

    context "there are multiple store credits" do
      context "they have different credit type priorities" do
        let(:amount_difference)       { 100 }
        let!(:primary_store_credit)   { create(:store_credit, amount: (order_total - amount_difference)) }
        let!(:secondary_store_credit) { create(:store_credit, amount: order_total, user: primary_store_credit.user, credit_type: create(:secondary_credit_type)) }
        let(:order)                   { create(:order, user: primary_store_credit.user, total: order_total) }

        before do
          subject
          order.reload
        end

        it "uses the primary store credit type over the secondary" do
          primary_payment = order.payments.first
          secondary_payment = order.payments.last

          expect(order.payments.size).to eq 2
          expect(primary_payment.source).to eq primary_store_credit
          expect(secondary_payment.source).to eq secondary_store_credit
          expect(primary_payment.amount).to eq(order_total - amount_difference)
          expect(secondary_payment.amount).to eq(amount_difference)
        end
      end
    end
  end

  describe "#covered_by_store_credit" do
    context "order doesn't have an associated user" do
      subject { create(:store_credits_order_without_user) }

      it "returns false" do
        expect(subject.covered_by_store_credit).to be false
      end
    end

    context "order has an associated user" do
      let(:user) { create(:user) }

      subject    { create(:order, user: user) }

      context "user has enough store credit to pay for the order" do
        before do
          user.stub(total_available_store_credit: 10.0)
          subject.stub(total: 5.0)
        end

        it "returns true" do
          expect(subject.covered_by_store_credit).to be true
        end
      end

      context "user does not have enough store credit to pay for the order" do
        before do
          user.stub(total_available_store_credit: 0.0)
          subject.stub(total: 5.0)
        end

        it "returns false" do
          expect(subject.covered_by_store_credit).to be false
        end
      end
    end
  end

  describe "#total_available_store_credit" do
    context "order does not have an associated user" do
      subject { create(:store_credits_order_without_user) }

      it "returns 0" do
        expect(subject.total_available_store_credit).to be_zero
      end
    end

    context "order has an associated user" do
      let(:user)                   { create(:user) }
      let(:available_store_credit) { 25.0 }

      subject { create(:order, user: user) }

      before do
        user.stub(total_available_store_credit: available_store_credit)
      end

      it "returns the user's available store credit" do
        expect(subject.total_available_store_credit).to eq available_store_credit
      end
    end
  end

  describe "#order_total_after_store_credit" do
    let(:order_total) { 100.0 }

    subject { create(:order, total: order_total) }

    before do
      subject.stub(total_applicable_store_credit: applicable_store_credit)
    end

    context "order's user has store credits" do
      let(:applicable_store_credit) { 10.0 }

      it "deducts the applicable store credit" do
        expect(subject.order_total_after_store_credit).to eq (order_total - applicable_store_credit)
      end
    end

    context "order's user does not have any store credits" do
      let(:applicable_store_credit) { 0.0 }

      it "returns the order total" do
        expect(subject.order_total_after_store_credit).to eq order_total
      end
    end
  end

  describe "#finalize!" do
    context "the order contains gift cards and transitions to complete" do
      let(:order) { create(:order_with_line_items, state: 'complete') }

      subject { order.finalize! }

      it "calls #create_gift_cards" do
        order.should_receive(:create_gift_cards)
        subject
      end
    end
  end

  describe "transition to complete" do
    let(:order) { create(:order_with_line_items, state: 'confirm') }
    let!(:payment) { create(:payment, order: order, state: 'pending') }
    subject { order.next! }

    it "calls #send_gift_card_emails" do
      order.should_receive(:send_gift_card_emails)
      subject
    end

  end

  describe "#total_applicable_store_credit" do
    context "order is in the confirm state" do
      before { order.update_attributes(state: 'confirm') }
      include_examples "check total store credit from payments"
    end

    context "order is completed" do
      before { order.update_attributes(state: 'complete') }
      include_examples "check total store credit from payments"
    end

    context "order is in any state other than confirm or complete" do
      context "the associated user has store credits" do
        let(:store_credit) { create(:store_credit) }
        let(:order)        { create(:order, user: store_credit.user) }

        subject { order }

        context "the store credit is more than the order total" do
          let(:order_total) { store_credit.amount - 1 }

          before { order.update_attributes(total: order_total) }

          it "returns the order total" do
            expect(subject.total_applicable_store_credit).to eq order_total
          end
        end

        context "the store credit is less than the order total" do
          let(:order_total) { store_credit.amount * 10 }

          before { order.update_attributes(total: order_total) }

          it "returns the store credit amount" do
            expect(subject.total_applicable_store_credit).to eq store_credit.amount
          end
        end
      end

      context "the associated user does not have store credits" do
        let(:order) { create(:order) }

        subject { order }

        it "returns 0" do
          expect(subject.total_applicable_store_credit).to be_zero
        end
      end

      context "the order does not have an associated user" do
        subject { create(:store_credits_order_without_user) }

        it "returns 0" do
          expect(subject.total_applicable_store_credit).to be_zero
        end
      end
    end
  end

  describe "#display_total_applicable_store_credit" do
    let(:total_applicable_store_credit) { 10.00 }

    subject { create(:order) }

    before { subject.stub(total_applicable_store_credit: total_applicable_store_credit) }

    it "returns a money instance" do
      expect(subject.display_total_applicable_store_credit).to be_a(Spree::Money)
    end

    it "returns a negative amount" do
      expect(subject.display_total_applicable_store_credit.money.cents).to eq (total_applicable_store_credit * -100.0)
    end
  end

  describe "#display_order_total_after_store_credit" do
    let(:order_total_after_store_credit) { 10.00 }

    subject { create(:order) }

    before { subject.stub(order_total_after_store_credit: order_total_after_store_credit) }

    it "returns a money instance" do
      expect(subject.display_order_total_after_store_credit).to be_a(Spree::Money)
    end

    it "returns the order_total_after_store_credit amount" do
      expect(subject.display_order_total_after_store_credit.money.cents).to eq (order_total_after_store_credit * 100.0)
    end
  end

  describe "#display_total_available_store_credit" do
    let(:total_available_store_credit) { 10.00 }

    subject { create(:order) }

    before { subject.stub(total_available_store_credit: total_available_store_credit) }

    it "returns a money instance" do
      expect(subject.display_total_available_store_credit).to be_a(Spree::Money)
    end

    it "returns the total_available_store_credit amount" do
      expect(subject.display_total_available_store_credit.money.cents).to eq (total_available_store_credit * 100.0)
    end
  end

  describe "#display_store_credit_remaining_after_capture" do
    let(:total_available_store_credit)  { 10.00 }
    let(:total_applicable_store_credit) { 5.00 }

    subject { create(:order) }

    before do
      subject.stub(total_available_store_credit: total_available_store_credit,
      total_applicable_store_credit: total_applicable_store_credit)
    end

    it "returns a money instance" do
      expect(subject.display_store_credit_remaining_after_capture).to be_a(Spree::Money)
    end

    it "returns all of the user's available store credit minus what's applied to the order amount" do
      amount_remaining = total_available_store_credit - total_applicable_store_credit
      expect(subject.display_store_credit_remaining_after_capture.money.cents).to eq (amount_remaining * 100.0)
    end
  end
end