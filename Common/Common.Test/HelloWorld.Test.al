codeunit 90000 "HelloWorld Test"
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

