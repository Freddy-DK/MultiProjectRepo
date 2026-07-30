codeunit 90011 "HelloWorld Test W1"
{
    Subtype = Test;

    [Test]
    procedure TestHelloWorldMessage()
    var
        CustList: TestPage "Customer List";
    begin
        CustList.OpenView();
        CustList.Close();
    end;
}

